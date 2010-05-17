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
    default => sub { [qw/SSH Socks/] },
);

1;