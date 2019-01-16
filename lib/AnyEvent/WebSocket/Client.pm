package AnyEvent::WebSocket::Client;

use strict;
use warnings;
use Moo;
use AE;
use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Socket ();
use AnyEvent::Connector;
use Protocol::WebSocket::Request;
use Protocol::WebSocket::Handshake::Client;
use AnyEvent::WebSocket::Connection;
use PerlX::Maybe qw( maybe provided );

# ABSTRACT: WebSocket client for AnyEvent
# VERSION

=head1 SYNOPSIS

 use AnyEvent::WebSocket::Client 0.12;
 
 my $client = AnyEvent::WebSocket::Client->new;
 
 $client->connect("ws://localhost:1234/service")->cb(sub {
 
   # make $connection an our variable rather than
   # my so that it will stick around.  Once the
   # connection falls out of scope any callbacks
   # tied to it will be destroyed.
   our $connection = eval { shift->recv };
   if($@) {
     # handle error...
     warn $@;
     return;
   }
   
   # send a message through the websocket...
   $connection->send('a message');
   
   # recieve message from the websocket...
   $connection->on(each_message => sub {
     # $connection is the same connection object
     # $message isa AnyEvent::WebSocket::Message
     my($connection, $message) = @_;
     ...
   });
   
   # handle a closed connection...
   $connection->on(finish => sub {
     # $connection is the same connection object
     my($connection) = @_;
     ...
   });

   # close the connection (either inside or
   # outside another callback)
   $connection->close;
 
 });

 ## uncomment to enter the event loop before exiting.
 ## Note that calling recv on a condition variable before
 ## it has been triggered does not work on all event loops
 #AnyEvent->condvar->recv;

=head1 DESCRIPTION

This class provides an interface to interact with a web server that provides
services via the WebSocket protocol in an L<AnyEvent> context.  It uses
L<Protocol::WebSocket> rather than reinventing the wheel.  You could use 
L<AnyEvent> and L<Protocol::WebSocket> directly if you wanted finer grain
control, but if that is not necessary then this class may save you some time.

The recommended API was added to the L<AnyEvent::WebSocket::Connection>
class with version 0.12, so it is recommended that you include that version
when using this module.  The older version of the API has since been
deprecated and removed.

=head1 ATTRIBUTES

=head2 timeout

Timeout for the initial connection to the web server.  The default
is 30.

=cut

has timeout => (
  is      => 'ro',
  default => sub { 30 },
);

=head2 ssl_no_verify

If set to true, then secure WebSockets (those that use SSL/TLS) will
not be verified.  The default is false.

=cut

has ssl_no_verify => (
  is => 'ro',
);

=head2 ssl_ca_file

Provide your own CA certificates file instead of using the system default for
SSL/TLS verification.

=cut

has ssl_ca_file => (
  is => 'ro',
);

=head2 protocol_version

The protocol version.  See L<Protocol::WebSocket> for the list of supported
WebSocket protocol versions.

=cut

has protocol_version => (
  is => 'ro',
);

=head2 subprotocol

List of subprotocols to request from the server.  This class will throw an
exception if none of the protocols are supported by the server.

=cut

has subprotocol => (
  is     => 'ro',
  coerce => sub { ref $_[0] ? $_[0] : [$_[0]] },
);

=head2 http_headers

Extra headers to include in the initial request.  May be either specified
as a hash reference, or an array reference.  For example:

 AnyEvent::WebSocket::Client->new(
   http_headers => {
     'X-Foo' => 'bar',
     'X-Baz' => [ 'abc', 'def' ],
   },
 );
 
 AnyEvent::WebSocket::Client->new(
   http_headers => [
     'X-Foo' => 'bar',
     'X-Baz' => 'abc',
     'X-Baz' => 'def',
   ],
 );

Will generate:

 X-Foo: bar
 X-Baz: abc
 X-Baz: def

Although, the order cannot be guaranteed when using the hash style.

=cut

has http_headers => (
  is => 'ro',
  coerce => sub {
    ref $_[0] eq 'ARRAY' ? $_[0] : do {
      my $h = shift;
      [
        map {
          my($k,$v) = ($_, $h->{$_});
          $v = [$v] unless ref $v;
          map { $k => $_ } @$v;
          # sorted to make testing easier.
          # may be removed in the future
          # so do not depend on it.
        } sort keys %$h
      ],
    };
  },
);

=head2 max_payload_size

The maximum payload size for received frames.  Currently defaults to whatever
L<Protocol::WebSocket> defaults to.

=cut

has max_payload_size => (
  is => 'ro',
);

=head2 max_fragments

The maximum number of fragments for received frames.  Currently defaults to whatever
L<Protocol::WebSocket> defaults to.

=cut

has max_fragments => (
  is => 'ro',
);

=head2 env_proxy

If you set true to this boolean attribute, it loads proxy settings
from environment variables. If it finds valid proxy settings,
C<connect> method will use that proxy.

Default: false.

For C<ws> WebSocket end-points, first it reads C<ws_proxy> (or
C<WS_PROXY>) environment variable. If it is not set or empty string,
then it reads C<http_proxy> (or C<HTTP_PROXY>). For C<wss> WebSocket
end-points, it reads C<wss_proxy> (C<WSS_PROXY>) and C<https_proxy>
(C<HTTPS_PROXY>) environment variables.

=cut

has env_proxy => (
  is => 'ro',
  default => sub { 0 },
);


=head1 METHODS

=head2 connect

 my $cv = $client->connect($uri)
 my $cv = $client->connect($uri, $host, $port);
 my $cv = $client->connect($uri, \&prepare);
 my $cv = $client->connect($uri, $host, $port, \&prepare);

Open a connection to the web server and open a WebSocket to the resource
defined by the given URL.  The URL may be either an instance of L<URI::ws>,
L<URI::wss>, or a string that represents a legal WebSocket URL.

You can  override the connection host and port by passing them in as the
second and third argument.  These values (if provided) are passed directly
into L<AnyEvent::Socket>'s C<tcp_connect> function, so please note that
function's idiosyncrasies in the L<AnyEvent::Socket> documentation.  In
particular,  you can pass in C<unix/> as the host and a filesystem path
as the "port" to connect to a unix domain socket.

You can provide a prepare callback as the last argument.  This will be called
after the file handle is created, but before connecting.  This allows you
to bind to a specific local port, or set a timeout different from the
client object.  This is passed (if provided) directly into L<AnyEvent>'s
C<tcp_connect> function so read the documentation there for more details.

This method will return an L<AnyEvent> condition variable which you can 
attach a callback to.  The value sent through the condition variable will
be either an instance of L<AnyEvent::WebSocket::Connection> or a croak
message indicating a failure.  The synopsis above shows how to catch
such errors using C<eval>.

=cut

sub connect
{
  my $self = shift;
  my $uri = shift;
  my $prepare_cb = ref $_[-1] eq 'CODE' ? pop @_ : sub { $self->timeout };
  my($host, $port) = @_;
  unless(ref $uri)
  {
    require URI;
    $uri = URI->new($uri);
  }

  my $done = AE::cv;

  # TODO: should we also accept http and https URLs?
  # probably.
  if($uri->scheme ne 'ws' && $uri->scheme ne 'wss')
  {
    $done->croak("URI is not a websocket");
    return $done;
  }

  $host = $uri->host unless defined $host;
  $port = $uri->port unless defined $port;

  $self->_make_tcp_connection($uri->scheme, $host, $port, sub {
    my $fh = shift;
    unless($fh)
    {
      $done->croak("unable to connect");
      return;
    }
    my $req = Protocol::WebSocket::Request->new( maybe headers => $self->http_headers );
    my $handshake = Protocol::WebSocket::Handshake::Client->new(
            url     => $uri->as_string,
      maybe version => $self->protocol_version,
            req     => $req,
    );
    
    my %subprotocol;
    if($self->subprotocol)
    {
      %subprotocol = map { $_ => 1 } @{ $self->subprotocol };
      $handshake->req->subprotocol(join(',', @{ $self->subprotocol }));
    }
    
    my $hdl = AnyEvent::Handle->new(
                                                      fh       => $fh,
      provided $uri->secure,                          tls      => 'connect',
      provided $uri->secure && !$self->ssl_no_verify, peername => $uri->host,
      provided $uri->secure && !$self->ssl_no_verify, tls_ctx  => {
                                                              verify => 1,
                                                              verify_peername => "https",
                                                        maybe ca_file => $self->ssl_ca_file,
                                                      },
                                                      on_error => sub {
                                                        my ($hdl, $fatal, $msg) = @_;
                                                        if($fatal)
                                                        { $done->croak("connect error: " . $msg) }
                                                        else
                                                        { warn $msg }
                                                      },
    );

    $hdl->push_write($handshake->to_string);
    $hdl->on_read(sub {
      $handshake->parse($_[0]{rbuf});
      if($handshake->error)
      {
        $done->croak("handshake error: " . $handshake->error);
        undef $hdl;
        undef $handshake;
        undef $done;
      }
      elsif($handshake->is_done)
      {
        my $sb;
        if($self->subprotocol)
        {
          $sb = $handshake->res->subprotocol;
          if(defined $sb)
          {
            unless($subprotocol{$sb})
            {
              $done->croak("subprotocol mismatch, requested: @{[ join ', ', @{ $self->subprotocol } ]}, got: $sb");
            }
          }
          else
          {
            $done->croak("no subprotocol in response");
          }
        }
        undef $handshake;
        $done->send(
          AnyEvent::WebSocket::Connection->new(
                  handle               => $hdl,
                  masked               => 1,
            maybe subprotocol          => $sb,
            maybe max_payload_size     => $self->max_payload_size,
            maybe max_fragments        => $self->max_fragments,
          )
        );
        undef $hdl;
        undef $done;
      }
    });
  }, $prepare_cb);
  $done;
}

sub _make_tcp_connection
{
  my $self = shift;
  my $scheme = shift;
  my ($host, $port) = @_;
  if(!$self->env_proxy)
  {
    return &AnyEvent::Socket::tcp_connect(@_);
  }
  my @connectors =
      $scheme eq "ws"
      ? (map { AnyEvent::Connector->new(env_proxy => $_) } qw(ws http))
      : $scheme eq "wss"
      ? (map { AnyEvent::Connector->new(env_proxy => $_) } qw(wss https))
      : ();
  foreach my $connector (@connectors)
  {
    if(defined($connector->proxy_for($host, $port)))
    {
      return $connector->tcp_connect(@_);
    }
  }
  return &AnyEvent::Socket::tcp_connect(@_);
}

1;

=head1 FAQ

=head2 My program exits before doing anything, what is up with that?

See this FAQ from L<AnyEvent>: 
L<AnyEvent::FAQ#My-program-exits-before-doing-anything-whats-going-on>.

It is probably also a good idea to review the L<AnyEvent> documentation
if you are new to L<AnyEvent> or event-based programming.

=head2 My callbacks aren't being called!

Make sure that the connection object is still in scope.  This often happens
if you use a C<my $connection> variable and don't save it somewhere.  For
example:

 $client->connect("ws://foo/service")->cb(sub {
 
   my $connection = eval { shift->recv };
   
   if($@)
   {
     warn $@;
     return;
   }
   
   ...
 });

Unless C<$connection> is saved somewhere it will get deallocated along with
any associated message callbacks will also get deallocated once the connect
callback is executed.  One way to make sure that the connection doesn't
get deallocated is to make it a C<our> variable (as in the synopsis above)
instead.

=head1 CAVEATS

This is pretty simple minded and there are probably WebSocket features
that you might like to use that aren't supported by this distribution.
Patches are encouraged to improve it.

=head1 SEE ALSO

=over 4

=item *

L<AnyEvent::WebSocket::Connection>

=item *

L<AnyEvent::WebSocket::Message>

=item *

L<AnyEvent::WebSocket::Server>

=item *

L<AnyEvent>

=item *

L<URI::ws>

=item *

L<URI::wss>

=item *

L<Protocol::WebSocket>

=item *

L<Net::WebSocket::Server>

=item *

L<Net::Async::WebSocket>

=item *

L<RFC 6455 The WebSocket Protocol|http://tools.ietf.org/html/rfc6455>

=back

=begin stopwords

Joaquín José

=end stopwords

=cut
