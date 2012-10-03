#
# RTMPT.pm - Represents an RTMPT session
#
# (C) Daniel Burr 2010
#
# Information on the RTMPT protocol can be found at:
# http://www.joachim-bauch.de/tutorials/red5/rtmpt-protocol/
# http://wiki.gnashdev.org/RTMPT
#
package RTMPT;
use strict;
use HTTP::Parser; # libhttp-parser-perl under Debian
use HTTP::Status qw(:constants);
use Settings;


sub new($$) {
	my $type = shift;
	my $class = ref $type || $type;
	my($sock_in, $sock_out) = @_;

	my $host = $TARGET_HOST || Net::Proxy::Connector::transparent::get_original_destination_host($sock_in);
	$host .= ':';
	$host .= $TARGET_PORT || Net::Proxy::Connector::transparent::get_original_destination_port($sock_in);

	# use absolute path if using a HTTP proxy
	my $path = defined($PROXY_HOST)? "http://$host": '';

	my $polling_interval = defined($FORCED_POLLING_RATE)? $FORCED_POLLING_RATE: 1;

	my $self = bless {
		'socket'           => $sock_out,
		'destination_path' => $path,
		'destination_host' => $host,
		'state'            => 0, # 0: init, 1: open sent, 2: running
		'client_id'        => undef, # from response to 'open' command
		'initdata'         => undef, # data to send in first 'send' message
		'message_counter'  => 1,
		'curr_time'        => 0, # current time interval
		'next_time'        => -1, # default will never match
		'polling_interval' => $polling_interval,
		'parser'           => new HTTP::Parser(response => 1),
		'unacked'          => 0, # number of requests with no response
	}, $class;

	$self;
}


sub create_header($$$$) {
	my($self, $sequence_id, $length, $cmd) = @_;

	$sequence_id = '\d+' if(!defined($sequence_id));

	return (
		"POST $self->{destination_path}/$cmd/$sequence_id HTTP/1.1",
		"Host: $self->{destination_host}",
		"User-Agent: Shockwave Flash",
#               "X-Forwarded-For: Someone else", # TODO: might be useful
		"Connection: Keep-Alive",
#		"Keep-Alive: 300",
		"Cache-Control: no-cache",
		"Content-Type: application/x-fcs",
		"Content-Length: $length",
		""
	);
}


sub create_message($$$) {
	my($self, $cmd, $content) = @_;

	my @retval = $self->create_header($self->{message_counter}, length($content), $cmd);
	push @retval, $content;

	$self->{message_counter}++;
	$self->{unacked}++;
	$self->{next_time} = $self->{curr_time} + $self->{polling_interval};
	$DEBUG > 3 && print "Interval: $self->{next_time} = $self->{curr_time} + $self->{polling_interval}\n";

	return join("\r\n", @retval);
}


=item handle_content
Determine the polling interval from a C<HTTP::Response> object and return
the rest of the data
=cut
sub handle_content($$) {
	my($self, $response) = @_;

	my $data = $response->content();
	if(!length($data)) {
		print "Zero length content!\n";
		return '';
	}

	$self->{'polling_interval'} = defined($FORCED_POLLING_RATE)? $FORCED_POLLING_RATE: ord($data);

	return substr($data, 1);
}


sub get_open_msg($) { return $_[0]->create_message("open", "\0"); }

sub get_idle_msg($) { return $_[0]->create_message("idle/$_[0]->{client_id}", "\0"); }

sub get_send_msg($$) { return $_[0]->create_message("send/$_[0]->{client_id}", $_[1]); }

sub get_close_msg($) { return $_[0]->create_message("close/$_[0]->{client_id}", "\0"); }


=item connection_valid
Return 1 if both ends of the connection are still open.
One connector may be closed while the other is still open
while it writes out the last of the data from it's buffer.
=cut
sub connection_valid($) {
	my $self = shift || die;
	
	my $sock_out = $self->{socket};
	# outgoing connection is closed (incoming connection must still be open)
	return 0 if(!defined(Net::Proxy->get_connector($sock_out)));

	my $sock_in = Net::Proxy->get_peer($sock_out);
	# incoming connection is closed (outgoing connection must still be open)
	return 0 if(!defined(Net::Proxy->get_connector($sock_in)));

	return 1;
}


sub handle_client($$) {
	my($self, $dataref) = @_;

	$DEBUG > 2 && printf("State %i: recv %i bytes from client\n", $self->{state}, length($$dataref));

	return if(!$self->connection_valid());

	if($self->{state} == 0) {
		$self->{initdata} = $$dataref; # back up original data

		$DEBUG > 0 && printf("Stream type %i\n", ord($$dataref));

		# overwrite it with open command
		$$dataref = $self->get_open_msg();
		$self->{state} = 1;
		$self->{message_counter} = 0; # reset counter
	} else {
		$$dataref = $self->get_send_msg($$dataref);
	}
	$DEBUG > 2 && printf("State %i: write %i bytes to server\n", $self->{state}, length($$dataref));
}


sub handle_response {
	my($self, $response, $dataref) = @_;

	$self->{unacked}--;
	$DEBUG > 2 && printf "Waiting for %i more responses\n", $self->{unacked};

	return if(!$self->connection_valid());

	if($response->code() != HTTP_OK) {
		printf "Unexpected HTTP return code received (%i).  Content was:\n%s\n", $response->code(), $response->content();

		# send close message
		$self->send_data_to_server($self->get_close_msg());

		# TODO: add a feature to retry sending last request n times

		my $sock = $self->{socket};
		my $peer = Net::Proxy->get_peer($sock);
		Net::Proxy->close_sockets($sock, $peer);
		return;
	}

	$DEBUG > 1 && printf "Got response, code %i, length %s\n", $response->code(), $response->header('Content-Length');     

	if($self->{state} == 1) { # expecting response to "open", which will contain client ID
		$self->{client_id} = $response->content();
		chomp $self->{client_id};
		$DEBUG > 0 && print "Client id $self->{client_id}\n";

		$self->{state} = 2;

		$self->send_data_to_server($self->get_send_msg($self->{initdata}));
	} else {
		$$dataref .= $self->handle_content($response);
	}
}


sub handle_server($$) {
	my($self, $dataref) = @_;

	$DEBUG > 2 && printf("State %i: received %i bytes from server\n", $self->{state}, length($$dataref));

	my $parser = $self->{parser};

	my $parse_status = $parser->add($$dataref);

	$$dataref = ""; # send nothing back to client unless we find responses
	
	if($parse_status == 0) {
		do {
			$self->handle_response($parser->object(), $dataref);
			$parser->{state} = 'blank';
		} while($parser->extra() > 0 && $parser->add() == 0);
	}

	$DEBUG > 1 && print $parser->extra(), " bytes unparsed\n";

	$DEBUG > 2 && printf("State %i: write %i bytes to client\n", $self->{state}, length($$dataref));
}


=item update_interval
Called every time interval to check if the idle timeout has elapsed.
If so, an IDLE command is queued for sending to the server.
=cut
sub update_interval($$) {
	my($self, $current_interval) = @_;

	$self->{curr_time} = $current_interval;

	return if(!$self->connection_valid || $self->{next_time} != $current_interval ||
	    $self->{state} != 2 || $IDLE_DISABLED == 1);

	return if(defined($MAX_REQUEST_WAIT) && $self->{unacked} > $MAX_REQUEST_WAIT);

	# if the send buffer still contains an idle request then we
	# don't send send a new one.  Instead we increment next_time so we
	# will check it again in the next time interval.
	my $data = Net::Proxy->get_buffer($self->{socket});
=item
	# Can't do this because $data might not begin with a HTTP request
	my $parser = new HTTP::Parser(request => 1);
	if($parser->add($data) == 0 && $parser->object()->uri() =~ m|/idle/$self->{client_id}/|)
=cut
	my $idle_regex = join "\r\n", $self->create_header(undef, 1, "idle/$self->{client_id}");
	if($data =~ /$idle_regex/) {
		$self->{next_time}++;
		return;
	}

	$self->send_data_to_server($self->get_idle_msg());
}


sub send_data_to_server($$) {
	my($self, $data) = @_;

	return if(!defined($data) or $data eq '');

	$DEBUG > 0 && printf "Sending %i bytes to server\n", length($data);

	my $sock = $self->{socket};
	Net::Proxy->add_to_buffer($sock, $data);
	Net::Proxy->watch_writer_sockets($sock);
}


1;
