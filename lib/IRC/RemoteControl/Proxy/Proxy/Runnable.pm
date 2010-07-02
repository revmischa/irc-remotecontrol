# version of Proxy::Proxy that can be run as a script

package IRC::RemoteControl::Proxy::Proxy::Runnable;

use Moose;
with 'MooseX::Getopt';
with 'IRC::RemoteControl::Proxy::Proxy';

use namespace::autoclean;

__PACKAGE__->meta->make_immutable;

