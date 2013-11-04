use strict;
use warnings;
use v5.10;
use AnyEvent::WebSocket::Client;
use Test::More;
use FindBin ();
use lib $FindBin::Bin;
use testlib::Server;

testlib::Server->set_timeout;

my $uri = testlib::Server->start_echo;

my $connection = AnyEvent::WebSocket::Client->new()->connect($uri)->recv;
ok $connection->masked, "Client Connection should set masked => true";

done_testing;
