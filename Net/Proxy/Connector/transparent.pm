package Net::Proxy::Connector::transparent;
use strict;
use warnings;
use IO::Socket::INET;
use Carp;
use Socket qw/inet_ntoa sockaddr_in/;
use Net::Proxy::Connector;
our @ISA = qw( Net::Proxy::Connector );

# not defined by Socket.pm, so taken from bits/in.h
use constant SOL_IP => 0;
# not defined by Socket.pm, so taken from linux/netfilter_ipv4.h
use constant SO_ORIGINAL_DST => 80;

sub init {
    my ($self) = @_;

    # set up some defaults
    $self->{timeout} ||= 1;

    if(exists($self->{host})) {
        croak "'host' key is not a CODE reference" if ref( $self->{host} ) ne 'CODE';
    } else {
        $self->{host} = \&get_original_destination_host;
    }

    if(exists($self->{port})) {
        croak "'port' key is not a CODE reference" if ref( $self->{port} ) ne 'CODE';
    } else {
        $self->{port} = \&get_original_destination_port;
    }
}

sub get_original_destination_host($) {
    my $sockaddr_in = substr(getsockopt($_[0], SOL_IP, SO_ORIGINAL_DST), 0, 16);
    my($port, $packed_addr) = sockaddr_in($sockaddr_in);
    return inet_ntoa $packed_addr;
}

sub get_original_destination_port($) {
    my $sockaddr_in = substr(getsockopt($_[0], SOL_IP, SO_ORIGINAL_DST), 0, 16);
    my($port) = sockaddr_in($sockaddr_in);
    return $port;
}

# IN

# OUT
sub connect {
    my ($self) = @_;

    croak "No incoming connection" if(!defined($self->{conn}));

    my $host = &{$self->{host}}($self->{conn});
    my $port = &{$self->{port}}($self->{conn});
    delete $self->{conn}; # no longer needed

    my $sock = IO::Socket::INET->new(
        PeerAddr  => $host,
        PeerPort  => $port,
        Proto     => 'tcp',
        Timeout   => $self->{timeout},
    );
    die $! unless $sock;
    return $sock;
}

sub _out_connect_from {
    my ($self, $sock) = @_;

    $self->{conn} = $sock; # get reference to incoming connection
    $self->SUPER::_out_connect_from($sock);
}

# READ
*read_from = \&Net::Proxy::Connector::raw_read_from;

# WRITE
*write_to = \&Net::Proxy::Connector::raw_write_to;

1;

__END__

=head1 NAME

Net::Proxy::Connector::transparent - Net::Proxy connector for transparent proxies

=head1 SYNOPSIS

    # sample proxy using Net::Proxy::Connector::transparent
    use Net::Proxy;

    my $proxy = Net::Proxy->new(
        in  => { type => tcp, port => '6789' },
        out => { type => transparent },
    );

    $proxy->register();

    Net::Proxy->mainloop();

=head1 DESCRIPTION

C<Net::Proxy::Connector::transparent> is a connector for use with the
REDIRECT rule in netfilter.  It establishes an outgoing connection 
to the original destination of incoming connector.  This behaviour
can be overridden so that, for example, the outgoing connection is
established to the original destination host but to a different port.

=head1 CONNECTOR OPTIONS

The connector accept the following options:

=head2 C<out>

=over 4

=item * host

Optional code reference to be used to determine the outgoing host.  Defaults
to using the original destination host of the incoming connector.

=item * port

Optional code reference to be used to determine the outgoing port.  Defaults
to using the original destination port of the incoming connector.

=item * timeout

The socket timeout for connection.

=back

=head1 OVERRIDE FUNCTIONS

As described above, the C<host> and C<port> options allow a code reference
to be specified to override the default behaviour, which is to establish
a connection to the original destination of the incoming connector.  
The code reference should have the following signature:

    sub callback {
        my $sock = @_;
        ...
    }

Where C<$sock> indicates the socket on which the incoming connection was
received.  The exact type of the socket depends on the type of the incoming
connector but it should inherit from C<IO::Socket>.

=head1 AUTHOR

Daniel Burr, C<< <dburr@topcon.com> >>.

=head1 TODO

Add support for for other platforms, e.g. ipfw on FreeBSD, similar to C<Net::ProxyMod>

=head1 COPYRIGHT

Copyright 2010 Daniel Burr, All Rights Reserved.

=head1 LICENSE

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

