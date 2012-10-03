package Net::Proxy::Connector::session;
use Net::Proxy::Connector::transparent;
use RTMPT;
use Settings;
use strict;
our @ISA = qw(Net::Proxy::Connector::transparent);


# key is the string returned by ref()
our %session_list_in = ();
our %session_list_out = ();


sub _out_connect_from {
	my($self, $sockin) = @_;

	$self->SUPER::_out_connect_from($sockin);
	my $sockout = Net::Proxy->get_peer($sockin);
	return if(!$sockout); # outgoing connection failed
	my $session = new RTMPT($sockin, $sockout);
	$session_list_in{$sockin} = $session;
	$session_list_out{$sockout} = $session;

	$DEBUG > 0 && print "Start session, in $sockin, out $sockout\n";
}


sub close {
	my($self, $sockout) = @_;

	my $sockin = Net::Proxy->get_peer($sockout);

	my $session_in = $session_list_in{$sockin};
	my $session_out = $session_list_out{$sockout};

	print "No out session matching $sockout\n" if(!defined($session_in));
	print "No in session matching $sockin\n" if(!defined($session_out));
	print "Sessions do no match, in: $session_in, out: $session_out\n", if($session_in != $session_out);

	$DEBUG > 0 && print "End session, in $sockin, out $sockout\n";

	delete $session_list_out{$sockout};
	delete $session_list_in{$sockin};
}


1;
