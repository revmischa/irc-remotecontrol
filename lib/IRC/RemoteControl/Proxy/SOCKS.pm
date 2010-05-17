package IRC::RemoteControl::Proxy::SOCKS;

use Moose;
with 'IRC::RemoteControl::Proxy';

use namespace::autoclean;
use Carp qw/croak/;

use IO::Socket::Socks;

has 'socks' => (
    is => 'rw',
    isa => 'IO::Socket::Socks',
);

before 'reset' => sub {
    my ($self) = @_;
    
};

sub prepare {
    my ($self) = @_;
    
    my $socks = new IO::Socket::Socks(
        ProxyAddr   => $self->proxy_address,
        ProxyPort   => $self->proxy_port,
        ConnectAddr => $self->dest_address,
        ConnectPort => $self->dest_port
    );
    
    $self->socks($socks);
    
    return $socks;
}

sub run {
    my ($self, $comm_sock) = @_;
    
    my $socks = $self->socks or return;
    $self->run_select_loop($comm_sock, $socks);
}

sub write {
    my ($self, $data) = @_;
    
    return unless $self->socks;
    return $self->socks->write($data);
}

__PACKAGE__->meta->make_immutable;
