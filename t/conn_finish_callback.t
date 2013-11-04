use strict;
use warnings;
use Test::More;
use AnyEvent;
use AnyEvent::WebSocket::Connection;
use FindBin ();
use lib $FindBin::Bin;
use testlib::Server;
use testlib::Connection;

testlib::Server->set_timeout();

note("finish callback should be called only once");

sub test_case
{
  my ($label, $code) = @_;
  subtest $label, sub {
    my @conns = testlib::Connection->create_connection_pair();
    my $finish_count = 0;
    my $cv_finish = AnyEvent->condvar;
    $conns[0]->on(finish => sub { $finish_count++; $cv_finish->send });
    
    $code->(\@conns);
    
    $cv_finish->recv;
    $conns[0]->send("hoge");
    $conns[0]->send("foo");
    $conns[0]->send("bar");
    is $finish_count, 1;
  };
}

test_case "delete conn 1", sub {
  my $conns = shift;
  undef $conns->[1];
};

test_case "close conn 1", sub {
  my $conns = shift;
  $conns->[1]->close();
};

test_case "close conn 0", sub {
  my $conns = shift;
  $conns->[0]->close();
};

done_testing;
