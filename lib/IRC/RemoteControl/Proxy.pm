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

has 'timeout' => (
    is => 'rw',
    default => 8,
);

# # #

has 'type' => (
    is => 'ro',
    isa => 'Str',
    required => 1,
);

has 'on_read' => (
    is => 'rw',
    isa => 'CodeRef',
    clearer => 'clear_read_handler',
);

has 'ready' => (
    is => 'rw',
    isa => 'Bool',
);

has 'connecting' => (
    is => 'rw',
    isa => 'Bool',
);

has 'auth_failed' => (
    is => 'rw',
    isa => 'Bool',
);

has 'ok' => (
    is => 'rw',
    isa => 'Bool',
);

has 'in_use' => (
    is => 'rw',
    isa => 'Bool',
);

has 'retried' => (
    is => 'rw',
    isa => 'Int',
    default => 0,
);

has 'comm_handle' => (
    is => 'rw',
    clearer => 'clear_comm_handle',
);

has 'comm_handle_fh' => (
    is => 'rw',
    clearer => 'clear_comm_handle_fh',
);

has 'tunnel' => (
    is => 'rw',
    isa => 'IRC::RemoteControl::Proxy::Tunnel',
    clearer => 'clear_tunnel',
);


requires 'write';


sub kill_tunnel {
    my ($self) = @_;
    
    return unless $self->tunnel && $self->tunnel->subprocess;
    $self->tunnel->subprocess->kill(15);  # SIGTERM
}

sub reset {
    my ($self) = @_;
    
    $self->kill_tunnel;
    
    $self->clear_tunnel;
    $self->clear_comm_handle;
    $self->clear_comm_handle_fh;
    $self->clear_read_handler;
    $self->ready(0);
    $self->in_use(0);
    $self->connecting(0);
}

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
    
    return $self->type . " proxy via " . $self->proxy_connect_address . ':' . $self->proxy_connect_port;
}

1;
