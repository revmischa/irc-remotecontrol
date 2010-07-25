package IRC::RemoteControl::Proxy::HTTPS;

use Moose;
    extends 'IRC::RemoteControl::Proxy::HTTP';

use namespace::autoclean;

has 'scheme' => (
    is => 'ro',
    isa => 'Str',
    default => 'https',
);

__PACKAGE__->meta->make_immutable;
