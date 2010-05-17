package IRC::RemoteControl::Proxy::SSH;

use Moose;
with 'IRC::RemoteControl::Proxy';

use namespace::autoclean;
use Carp qw/croak/;

# requires libssh2 http://www.libssh2.org/
# Debian:   sudo aptitude install libssh2-1-dev
# OpenSUSE: sudo zypper in libssh2-1 libssh2-devel
use Net::SSH2;

our $SOURCE_PORT = 25432;

# unique local port number for tunnels
has 'source_port' => (
    is => 'rw',
    isa => 'Int',
    builder => 'build_source_port',
    lazy => 1,
);

has '_ssh' => (
    is => 'rw',
    predicate => 'has_ssh_client',
    clearer => 'clear_ssh_client',
    builder => 'build_ssh_client',
    lazy => 0,
);

has 'channel' => (
    is => 'rw',
    isa => 'Net::SSH2::Channel',
    clearer => 'clear_channel',
);

has 'type' => (
    is => 'ro',
    isa => 'Str',
    default => 'SSH',
);

has 'public_key_file' => (
    is => 'rw',
    isa => 'Str',
    default => '~/.ssh/id_rsa.pub',
);

has 'private_key_file' => (
    is => 'rw',
    isa => 'Str',
    default => '~/.ssh/id_rsa',
);

sub build_source_port {
    return $SOURCE_PORT++;
}

sub build_ssh_client {
    my ($self) = @_;
    
    my $ssh;
    
    $ssh = Net::SSH2->new();
    #$ssh->blocking(1); why does this not work 8[]
    
    return $ssh;
}

before 'reset' => sub {
    my ($self) = @_;
    
    $self->_ssh->disconnect if $self->has_ssh_client;    
    $self->clear_ssh_client;
};

around 'prepare' => sub {
    my ($orig, $self) = @_;
    
    my $ssh = $self->_ssh;
    
    # log in
    my $user = $self->username;
    my $pass = $self->password;
    my $ok;

    $ok = eval {
        return unless $ssh;
        
        $ssh->connect($self->proxy_address, $self->proxy_port, Timeout => $self->timeout) or die $!;
        
        # should add key auth filenames here if needed
        if ( $ssh->auth(
            rank => [qw/publickey password/],
            publickey => $self->public_key_file,
            privatekey => $self->private_key_file,
            username => $user, 
            password => $pass) ){
                
            # - logged in ok -
            
            return 1;
        } else {
            # failed to log in
            $self->reset;
            return;
        }
    };
    warn $@ if $@;
    return if ($@ || ! $ok);
    
    # behave nicely
    $self->$orig();
    
    return 1;
};

sub create_channel {
    my ($self) = @_;
    
    # create channel from ssh host to irc server
    my $channel = $self->_ssh->tcpip(
        $self->dest_address => $self->dest_port,
        '127.0.0.1' => $self->source_port,
    );
    return unless $channel;
    
    $self->channel($channel);
    return $channel;
}

# run until EOF
sub run {
    my ($self, $sock) = @_;
    
    $self->create_channel unless $self->channel;
    unless ($self->channel) {
        return 0;
    }
    
    while (! $self->channel->eof) {        
        # is there data from parent process to send through tunnel?
        my $buf;
        if (my $r = $sock->read($buf, 512)) {
            $self->write($buf);
        }
        
        my @lines;
        {
            local $/ = "\r\n";
            @lines = $self->channel->READLINE;
        }
        
        next unless @lines;
        
        if ($self->on_read) {
            $self->on_read->($_) foreach @lines;
        } else {
            print $_ foreach @lines;
        }
        
        $self->channel->flush;
    }
    
    $self->reset;
    return 1;
}

sub write {
    my ($self, $data) = @_;
    
    return unless $self->channel;
    
    my @lines = split(/\r?\n/, $data);
    foreach my $line (@lines) {
        $self->channel->PRINT("$line\r\n");
    }
    
    $self->channel->flush;
}

no Moose;
__PACKAGE__->meta->make_immutable;
