package IRC::RemoteControl::Proxy;

use Moose::Role;
use namespace::autoclean;

use IO::Select;

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
    isa => 'Int',
    default => 8,
);

has 'poll_timeout' => (
    is => 'rw',
    default => 0.25,
);


# # #

# automatically create subprocess to manage tunnel?
has 'needs_tunnel' => (
    is => 'ro',
    isa => 'Bool',
    default => 1,
);

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
requires 'run';


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

# run until EOF
sub run_select_loop {
    my ($self, $comm_sock, $proxy_sock) = @_;
    
    my $s = IO::Select->new($proxy_sock, $comm_sock);
    
    my $read_buf = '';
    
    while (my @ready = $s->can_read($self->poll_timeout)) {
        foreach my $fh (@ready) {
            if ($fh == $proxy_sock) {
                # data on proxy
                my $buf;
                $fh->read($buf, 512);
                $read_buf .= $buf;
                                
                # find lines
                my @lines;
                READLINES: while (1) {
                    my $eol_idx = index($read_buf, "\r\n");
                    if ($eol_idx != -1) {
                        my $line = substr($read_buf, 0, $eol_idx, '');
                        push @lines, $line;
                    } else {
                        last READLINES;
                    }
                }
                
                if ($self->on_read) {
                    $self->on_read->($_) foreach @lines;
                } else {
                    print $_ foreach @lines;
                }
            } elsif ($fh == $comm_sock) {
                # data from poarent process we need to write to proxy
                my $buf;
                if (my $r = $proxy_sock->read($buf, 512)) {
                    $comm_sock->write($buf);
                }
            } else {
                # done?
                $self->reset;
                return 1;
            }
        }
    }
    
    $self->reset;
    return 1;
}

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
