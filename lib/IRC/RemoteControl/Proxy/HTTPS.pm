package IRC::RemoteControl::Proxy::HTTPS;

use Moose;
    extends 'IRC::RemoteControl::Proxy::HTTP';

use namespace::autoclean;

__PACKAGE__->meta->make_immutable;
