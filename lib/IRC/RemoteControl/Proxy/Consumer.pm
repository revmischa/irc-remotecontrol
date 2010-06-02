package IRC::RemoteControl::Proxy::Consumer;

use Moose::Role;
use namespace::autoclean;

# REQUIRED: target network

has 'target_address' => (
    is => 'rw',
    isa => 'Str',
    required => 1,
);

has 'target_port' => (
    is => 'rw',
    isa => 'Int',
    default => 6667,
);

# OPTIONAL

has 'debug' => (
    is => 'rw',
    isa => 'Bool',
);

has 'fetch_socks_proxies' => (
    is => 'rw',
    isa => 'Bool',
);

has 'proxy_types' => (
    is => 'rw',
    isa => 'ArrayRef',
    default => sub { [qw/SSH SOCKS/] },
);

has 'use_proxy' => (
    is => 'rw',
    isa => 'Int',
    default => 1,
);

# available IPv6 prefixes
has 'ipv6_prefixes' => (
    is => 'rw',
    isa => 'ArrayRef',
    default => sub { [] },
);

# number of tunnels to create per-prefix
has 'ipv6_tunnel_count' => (
    is => 'rw',
    isa => 'Int',
    default => 100_000,
);

1;