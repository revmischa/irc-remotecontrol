package IRC::RemoteControl::Proxy::SSH;

use Moose;
with 'IRC::RemoteControl::Proxy';

use namespace::autoclean;
use AnyEvent::Socket;
use Carp qw/croak/;

#use Net::SSH::Perl;
our $use_net_ssh_perl = 0;

# requires libssh2 http://www.libssh2.org/
# Debian:   sudo aptitude install libssh2-1-dev
# OpenSUSE: sudo zypper in libssh2-1 libssh2-devel
use Net::SSH2;

our $tun_port = 30000; # start tunnel port range
has 'tunnel_port' => (
    is => 'rw',
    isa => 'Int',
    builder => 'build_tunnel_port',
);

has '_ssh' => (
    is => 'rw',
    builder => 'build_ssh_client',
);

has 'channel' => (
    is => 'rw',
    isa => 'Net::SSH2::Channel',
);

has 'tunnel_handle' => (
    is => 'rw',
    clearer => 'clear_tunnel_handle',
);

has 'channel_handle' => (
    is => 'rw',
    clearer => 'clear_channel_handle',
);

has 'tunnel_server' => (
    is => 'rw',
    clearer => 'clear_tunnel_server',
);

sub build_tunnel_port {
    return $tun_port++;
}

sub build_ssh_client {
    my ($self) = @_;
    
    my $ssh;
    
    # construct ssh client object
    if ($use_net_ssh_perl) {
        # not using this module anymore - no tunnel support
        $ssh = Net::SSH::Perl->new($self->proxy_address,
            use_pty => 0,
            interactive => 0,
            debug => 1,
        );
    
        # configure tunnel
        my $localport = $self->tunnel_port;
        my $addr = $self->dest_address;
        my $port = $self->dest_port;
        $ssh->config->set('LocalForward' => "$localport $addr:$port");
    } else {
        $ssh = Net::SSH2->new();
        #$ssh->blocking(1); why does this not work 8[]
    }
    
    return $ssh;
}

around 'prepare' => sub {
    my ($orig, $self) = @_;
    
    my $ssh = $self->_ssh;
    
    # log in
    my $user = $self->username;
    my $pass = $self->password;
    my $ok;
    if ($use_net_ssh_perl) {
        $ok = eval {
            return $ssh->login($user, $pass, 1);
        };
    } else {
        $ok = eval {
            $ssh->connect($self->proxy_address) or die $!;
            
            # should add key auth filenames here if needed
            if ($ssh->auth(
                username => $user,
                password => $pass,
            )) {
                # - logged in ok -
                
                # create channel from ssh host to irc server
                my $channel = $ssh->tcpip(
                    $self->dest_address => $self->dest_port,
                );
                $self->channel($channel);
                
                # create tunnel
                $self->create_tunnel_listener;
                
                return 1;
            } else {
                # failed to log in
                return;
            }
        };
    }
    warn $@ if $@;
    return if ($@ || ! $ok);
    
    # behave nicely
    $self->$orig();
    
    return 1;
};

sub create_tunnel_listener {
    my ($self) = @_;
    
    my ($tunnel_handle, $channel_handle);
    my $channel = $self->channel or croak "no channel defined";
    
    my $cleanup = sub {
        $self->clear_tunnel_handle;
        $self->clear_channel_handle;
        $self->clear_tunnel_server;
    };
    
    my $server_listen_address = $self->proxy_connect_address;
    
    # create tcp server
    my $fh;
    my $server = tcp_server $server_listen_address, $self->proxy_connect_port, sub {
        $fh = shift;
        my ($host, $port) = @_;
       
        # create handle to forward data over the ssh connection
        $tunnel_handle = new AnyEvent::Handle
           fh => $fh,
           on_eof => sub {
               $cleanup->();
           },
           on_error => sub {
               my (undef, $fatal, $msg) = @_;
               warn "Got fatal error on server socket: $msg";
               $tunnel_handle->destroy if $tunnel_handle;
               $channel_handle->destroy if $channel_handle;
               $cleanup->();
           },
           on_read => sub {
                $channel->write($tunnel_handle->rbuf);
           };

        $self->tunnel_handle($tunnel_handle);
    };
    $self->tunnel_server($server);
    
    $channel->blocking(0);
    
    # create handle to forward data from the ssh host
    # $channel_handle = new AnyEvent::Handle
    #     fh => $channel,  # channel is a tied filehandle
    #     on_eof => sub {
    #         $cleanup->();
    #     },
    #     on_error => sub {
    #         my (undef, $fatal, $msg) = @_;
    #         warn "Got fatal error on server socket: $msg";
    # $tunnel_handle->destroy if $tunnel_handle;
    # $channel_handle->destroy if $channel_handle;
    #         $cleanup->();
    #     },
    #     on_read => sub {
    #          syswrite $fh, $channel_handle->rbuf;
    #     };
    # $self->channel_handle($channel_handle);
    
    warn "servers created";
}

# address for proxy clients
sub proxy_connect_address {
    my ($self) = @_;
    
    return "127.0.0.1";
}

# local end of the tunnel
sub proxy_connect_port {
    my ($self) = @_;
    
    return $self->tunnel_port;
}

no Moose;
__PACKAGE__->meta->make_immutable;
