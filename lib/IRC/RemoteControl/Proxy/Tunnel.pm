package IRC::RemoteControl::Proxy::Tunnel;

# This represents an active tunnel

use Moose;
use namespace::autoclean;

our $TUNNEL_ID = 1;

has 'id' => (
    is => 'ro',
    isa => 'Int',
    builder => 'build_tunnel_id',
);

has 'proxy' => (
    is => 'rw',
    does => 'IRC::RemoteControl::Proxy',
    required => 1,
    handles => [qw/proxy_address proxy_port write/],
);

has 'subprocess' => (
    is => 'rw',
);

has 'type' => (
    is => 'ro',
    isa => 'Str',
    required => 1,
);

sub build_tunnel_id { $TUNNEL_ID++ }

__PACKAGE__->meta->make_immutable;
