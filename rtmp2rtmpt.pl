#!/usr/bin/perl -w
#
# rtmp2rtmpt - RTMP to RTMPT gateway
#
# (C) 2010 Daniel Burr
#

use strict;
use Getopt::Long;

sub get_dirname() {
	return dirname(-l $0? readlink $0: $0);
}

BEGIN {
	# add script location to the search path
	use File::Basename;
	unshift @INC, get_dirname();
}

use Net::Proxy; # libnet-proxy-perl under Debian
use Net::Proxy::Connector::session;
use Settings;


# According to Joachim Bauch, the polling interval is an amount of delay where
# the maximum delay is 0x21 == 500ms (therefore minimum delay is 1 == 15ms).
# So we break each second up into 66 intervals numbered 0-65.  After we
# send something to the server, we set the 'next_time' value to be equal to
# the current interval number plus 'polling_interval' (modulo 66).
# The timeout handler then uses update_interval() to check if the current
# interval matches any of the 'next_time' values
my $timeout = 1/66;
my $current_interval = 0;

sub fixed_select {
 shift
   if defined $_[0] && !ref($_[0]);

 my($r,$w,$e) = @_;
 my @result = ();

 my $rb = defined $r ? $r->[IO::Select::VEC_BITS] : undef;
 my $wb = defined $w ? $w->[IO::Select::VEC_BITS] : undef;
 my $eb = defined $e ? $e->[IO::Select::VEC_BITS] : undef;

 my $res = select($rb,$wb,$eb,$timeout);
 if($res > 0)
  {
   my @r = ();
   my @w = ();
   my @e = ();
   my $i = IO::Select::_max(defined $r ? scalar(@$r)-1 : 0,
                defined $w ? scalar(@$w)-1 : 0,
                defined $e ? scalar(@$e)-1 : 0);

   for( ; $i >= IO::Select::FIRST_FD ; $i--)
    {
     my $j = $i - IO::Select::FIRST_FD;
     push(@r, $r->[$i])
        if defined $rb && defined $r->[$i] && vec($rb, $j, 1);
     push(@w, $w->[$i])
        if defined $wb && defined $w->[$i] && vec($wb, $j, 1);
     push(@e, $e->[$i])
        if defined $eb && defined $e->[$i] && vec($eb, $j, 1);
    }

   @result = (\@r, \@w, \@e);
  } elsif($res == 0) { # timeout
   @result = ([], [], []);
   handle_timeout();
  }
 @result;
};

# we need to override this because the built-in version does not allow
# # us to differentiate between error and timeout, see the discussion at
# # http://www.perlmonks.org/?node_id=800472
undef *IO::Select::select;
*IO::Select::select = \&fixed_select;


sub handle_timeout {
	foreach my $session (values %Net::Proxy::Connector::session::session_list_out) {
		$session->update_interval($current_interval);
	}

	$current_interval++;
}


sub handle_in {
	my($dataref, $sock, $connector) = @_;

	my $session = $Net::Proxy::Connector::session::session_list_in{$sock};
	if(!defined($session)) {
		print "No session associated with incoming $sock\n";
		return;
	}

	$session->handle_client($dataref);
}


sub handle_out {
	my($dataref, $sock, $connector) = @_;

	my $session = $Net::Proxy::Connector::session::session_list_out{$sock};
	if(!defined($session)) {
		print "No session associated with outgoing $sock\n";
		return;
	}

	$session->handle_server($dataref);
}


sub get_host {
	my $sock = shift || die;

	my $host = $PROXY_HOST || $TARGET_HOST || Net::Proxy::Connector::transparent::get_original_destination_host($sock);
	print "Connecting to host $host\n";
	return $host;
}


sub get_port {
	my $sock = shift || die;

	my $port = $TARGET_PORT || Net::Proxy::Connector::transparent::get_original_destination_port($sock);
	$port = $PROXY_PORT if(defined($PROXY_HOST)); # use port if host specified
	print "Connecting to port $port\n";
	return $port;
}


sub start_proxy() {
	my $proxy = Net::Proxy->new(
		{
		in  => { type => 'tcp', host => $BIND_ADDRESS, port => $LISTEN_PORT, hook => \&handle_in },
		out => { type => 'session', host => \&get_host, port => \&get_port, hook => \&handle_out }
		}
	);

	$proxy->register();

	Net::Proxy->set_max_buffer_size(0);
	Net::Proxy->mainloop();
}


sub show_help() {
        print STDERR <<END;
$PROGRAM v$VERSION

Usage:

	$0 [-h|--help] [-a|--local-address <host>] [-l|--local-port <port>]
		[-t|--target-host <host>] [-p|--target-port <port>]
		[-x|--proxy-host <host>] [-y|--proxy-port <port>]
		[-i|--interval <num>] [--n|no-idle] [--max-requests|-m <num>]
		[-d|--debug <num>]

	--local-address: Local listening address
	                 (default: $BIND_ADDRESS)
	--local-port:    Local listening port
	                 (default: $LISTEN_PORT)
	--target-host:   Host name of target server
	                 (default: original IP of incoming connection)
	--target-port:   Port number to connect to on target server
	                 (default: original port of incoming connection)
	--proxy-host:    Use specified HTTP proxy
	                 (default: don't use HTTP proxy)
	--proxy-port     Port number to connect to on HTTP proxy
	                 (default: $PROXY_PORT)
	--interval:      Override polling interval with fixed value
	                 (default: use polling interval from server)
	--no-idle:       Do not send idle requests to server
	                 (default: idle requests will be sent to server)
	--max-requests:  Maximum number of outstanding requests
	                 (default: no limit)
	--debug:         Set level of debugging output
	                 (default: no debug output)

END
        die;
}

my %options = (
        'help'               => 0,
	'local-address'      => \$BIND_ADDRESS,
	'local-port'         => \$LISTEN_PORT,
	'target-host'        => \$TARGET_HOST,
	'target-port'        => \$TARGET_PORT,
	'target-port'        => \$TARGET_PORT,
	'proxy-host'         => \$PROXY_HOST,
	'proxy-port'         => \$PROXY_PORT,
	'interval'           => \$FORCED_POLLING_RATE,
	'no-idle'            => \$IDLE_DISABLED,
	'max-requests'       => \$MAX_REQUEST_WAIT,
	'debug'              => \$DEBUG,
);

my $result = GetOptions(
	"help|h"            => \$options{'help'},
	"local-address|a=s" =>  $options{'local-address'},
	"local-port|l=i"    =>  $options{'local-port'},
	"target-host|t=s"   =>  $options{'target-host'},
	"target-port|p=i"   =>  $options{'target-port'},
	"proxy-host|x=s"    =>  $options{'proxy-host'},
	"proxy-port|y=i"    =>  $options{'proxy-port'},
	"interval|i=i"      =>  $options{'interval'},
	"no-idle|n"         =>  $options{'no-idle'},
	"max-requests|m=i"  =>  $options{'max-requests'},
	"debug|d=i"         =>  $options{'debug'},
);

show_help() if(!$result || $options{'help'} == 1);

print "Starting $PROGRAM v$VERSION\n";
print "Listening for incoming RTMP connections on $BIND_ADDRESS:$LISTEN_PORT\n";
print "Outgoing RTMPT connections will be made to ";
print !defined($TARGET_HOST)? "IP of incoming connection": "host $TARGET_HOST";
print " on port ";
print !defined($TARGET_PORT)? "number of incoming connection": $TARGET_PORT;
print " via HTTP proxy $PROXY_HOST:$PROXY_PORT" if(defined($PROXY_HOST));
print "\n";

printf("Using specified polling interval of %i (%gs)\n", $FORCED_POLLING_RATE, $FORCED_POLLING_RATE * $timeout) if(defined($FORCED_POLLING_RATE));
print "Idle commands are disabled\n" if($IDLE_DISABLED == 1);
print "Idle requests will only be sent when less than $MAX_REQUEST_WAIT outstanding requests\n" if(defined($MAX_REQUEST_WAIT));

start_proxy();
