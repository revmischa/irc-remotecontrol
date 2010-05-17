package IRC::RemoteControl::Proxy::SOCKS;

use Moose;
with 'IRC::RemoteControl::Proxy';

use namespace::autoclean;
use Carp qw/croak/;

use IO::Socket::Socks;

has 'socks' => (
    is => 'rw',
    clearer => 'clear_socks',
);

before 'reset' => sub {
    my ($self) = @_;
  
    $self->clear_socks if $self->socks;
};

sub prepare {
    my ($self) = @_;
    
    # would be nice to test if it's valid before connecting...
    return 1;
}

sub run {
    my ($self, $comm_sock) = @_;
    
    my $socks = new IO::Socket::Socks(
        ProxyAddr   => $self->proxy_address,
        ProxyPort   => $self->proxy_port,
        ConnectAddr => $self->dest_address,
        ConnectPort => $self->dest_port,
    );
    
    unless ($socks) {
        my $err = $! || "unknown error";
        warn "SOCKS connect [$err]";
        return;
    }
    
    $self->socks($socks);

    return $self->run_select_loop($comm_sock, $socks);
}

sub write {
    my ($self, $data) = @_;
    
    return unless $self->socks;
    return $self->socks->write($data);
}

__PACKAGE__->meta->make_immutable;
