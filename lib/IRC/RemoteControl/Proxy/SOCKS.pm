package IRC::RemoteControl::Proxy::SOCKS;

use Moose;
with 'IRC::RemoteControl::Proxy';

use namespace::autoclean;
use Carp qw/croak/;

use IO::Socket::Socks;
use AnyEvent::Handle;

has 'socks' => (
    is => 'rw',
    clearer => 'clear_socks',
);

has 'check_timer' => (
    is => 'rw',
    clearer => 'clear_check_timer',
);

# IO::Socket::Socks is nonblocking
has '+needs_tunnel' => ( default => 0 );

before 'reset' => sub {
    my ($self) = @_;

    $self->clear_check_timer;
    $self->clear_socks;
};

sub prepare {
    my ($self) = @_;

    # would be nice to test if it's valid before connecting...
    my $socks = $self->create_socket or return;

    my $w = AnyEvent->timer(interval => 1,
                            cb => sub {
                                my $ready = $self->socks->ready;
                                #warn "ready: $ready" if $ready;
                                if ($IO::Socket::Socks::SOCKS_ERROR == IO::Socket::Socks->SOCKS_WANT_READ) {
                                    #warn "want_read";
                                    $self->ready(0);
                                } elsif ($IO::Socket::Socks::SOCKS_ERROR == IO::Socket::Socks->SOCKS_WANT_WRITE) {
                                    #warn "want_write";
                                    $self->ready(0);
                                } else {
                                    #warn "$IO::Socket::Socks::SOCKS_ERROR";
                                    $self->ok(0);
                                }
                                $self->ok($ready);
                                $self->ready($ready);
                            });
    $self->check_timer($w);
    return 1;
}

sub run {
    my ($self, $comm_sock) = @_;
    
    my $socks = $self->create_socket or return;
    return $self->run_select_loop($comm_sock, $socks);
}

sub create_socket {
    my ($self) = @_;

    my $socks = new IO::Socket::Socks(
        ProxyAddr   => $self->proxy_address,
        ProxyPort   => $self->proxy_port,
        ConnectAddr => $self->dest_address,
        ConnectPort => $self->dest_port,
        Blocking    => 0,
        SocksDebug  => 0,
    );
    
    unless ($socks) {
        my $err = $! || "unknown error";
        warn "SOCKS connect [$err]";
        return;
    }

    $self->comm_handle(new AnyEvent::Handle(
        fh => $socks,
        on_eof => sub {
            $self->ready(0);
        },
    ));
    
    $self->socks($socks);
    return $socks;
}

sub write {
    my ($self, $data) = @_;
    
    return unless $self->socks;
    return $self->socks->write($data);
}

__PACKAGE__->meta->make_immutable;
