package IRC::RemoteControl::Proxy;

use Moose::Role;
use namespace::autoclean;

has 'proxy_address' => (
    is => 'rw',
    isa => 'Str',
    required => 1,
);

has 'proxy_port' => (
    is => 'rw',
    isa => 'Str',
);

has 'dest_address' => (
    is => 'rw',
    isa => 'Str',
    required => 1,
);

has 'dest_port' => (
    is => 'rw',
    isa => 'Int',
    default => 6667,
);

has 'username' => (
    is => 'rw',
    isa => 'Str',
    required => 0,
);

has 'password' => (
    is => 'rw',
    isa => 'Str',
    required => 0,
);

has 'type' => (
    is => 'ro',
    isa => 'Str',
    required => 1,
);

has 'on_read' => (
    is => 'rw',
    isa => 'CodeRef',
);

has 'ready' => (
    is => 'rw',
    isa => 'Bool',
);

has 'in_use' => (
    is => 'rw',
    isa => 'Bool',
);

has 'comm_handle' => (
    is => 'rw',
    clearer => 'clear_comm_handle',
);

has 'comm_handle_fh' => (
    is => 'rw',
    clearer => 'clear_comm_handle_fh',
);


requires 'write';

sub prepare {}
sub run {}

sub proxy_connect_address {
    my ($self) = @_;
    return $self->proxy_address;
}

sub proxy_connect_port {
    my ($self) = @_;
    return $self->proxy_port;
}

sub description {
    my ($self) = @_;
    
    return $self->proxy_connect_address . ':' . $self->proxy_connect_port;
}

1;
