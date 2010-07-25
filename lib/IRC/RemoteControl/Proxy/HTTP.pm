package IRC::RemoteControl::Proxy::HTTP;

use Moose;
    with 'IRC::RemoteControl::Proxy';

use namespace::autoclean;
use Carp qw/croak/;

has 'needs_tunnel' => (
    is => 'ro',
    isa => 'Bool',
    default => 0,
);

# for now, default to ready state
has 'ok' => (
    is => 'rw',
    isa => 'Bool',
    default => 1,
);

has 'ready' => (
    is => 'rw',
    isa => 'Bool',
    default => 1,
);

has 'scheme' => (
    is => 'ro',
    isa => 'Str',
    default => 'http',
);

sub prepare {
    my ($self) = @_;    
    # would be nice to test if it's valid before connecting...
    return 1;
}

sub run {
    my ($self, $comm_sock) = @_;

    warn "Proxy::HTTP->run called. It shouldn't be!";
}

sub write {
    my ($self, $data) = @_;

    warn "Proxy::HTTP->write called. It shouldn't be!";    
}

__PACKAGE__->meta->make_immutable;
