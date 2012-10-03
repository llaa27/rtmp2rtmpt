#
# Settings.pm - User configurable options
#
# (C) Daniel Burr 2010
#
package Settings;

use strict;

our @ISA = qw(Exporter);
our @EXPORT = qw(
	$PROGRAM
	$VERSION
	$DEBUG
	$BIND_ADDRESS
	$LISTEN_PORT
	$TARGET_HOST
	$TARGET_PORT
	$PROXY_HOST
	$PROXY_PORT
	$FORCED_POLLING_RATE
	$IDLE_DISABLED
	$MAX_REQUEST_WAIT
);


our $PROGRAM = 'rtmp2rtmpt';
our $VERSION = 0.06;

our $DEBUG = 0;

our $BIND_ADDRESS = "0.0.0.0";
our $LISTEN_PORT = 8080;

our $TARGET_HOST = undef; # default, means to use IP of incoming connection
our $TARGET_PORT = undef; # default, means to use port of incoming connection

our $PROXY_HOST = undef; # default, means don't use HTTP proxy
our $PROXY_PORT = 80;

# polling rate control
our $FORCED_POLLING_RATE = undef; # default, use server-specified polling interval
our $IDLE_DISABLED = 0; # default, send idle requests
our $MAX_REQUEST_WAIT = undef; # default, no limit on outstanding requests

1;
