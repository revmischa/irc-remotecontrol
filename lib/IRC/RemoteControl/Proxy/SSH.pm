package IRC::RemoteControl::Proxy::SSH;

use Moose;
with 'IRC::RemoteControl::Proxy';

use namespace::autoclean;
use Net::SSH::Perl;

our $tun_port = 30000;
has 'tunnel_port' => (
    is => 'rw',
    isa => 'Int',
    builder => 'build_tunnel_port',
);

has '_ssh' => (
    is => 'rw',
);

sub build_tunnel_port {
    return $tun_port++;
} 

around 'prepare' => sub {
    my ($orig, $self) = @_;
        
    # construct ssh connection
    my $ssh = Net::SSH::Perl->new($self->proxy_address,
        use_pty => 0,
        interactive => 0,
        debug => 1,
    );
    
    # configure tunnel
    my $localport = $self->tunnel_port;
    my $addr = $self->dest_address;
    my $port = $self->dest_port;
    $ssh->config->set('LocalForward' => "$localport $addr:$port");
    
    # log in
    my $user = $self->username;
    my $pass = $self->password;
    my $ok = eval { $ssh->login($user, $pass, 1); };
    return if ($@ || ! $ok);
    
    # keep ssh object around so it's not destroyed
    $self->_ssh($ssh);
    
    # behave nicely
    $self->$orig();
    
    return 1;
};

# address for proxy clients
sub proxy_connect_address {
    my ($self) = @_;
    
    return "localhost";
}

# local end of the tunnel
sub proxy_connect_port {
    my ($self) = @_;
    
    return $self->tunnel_port;
}

no Moose;
__PACKAGE__->meta->make_immutable;
