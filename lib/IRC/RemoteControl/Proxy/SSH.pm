package IRC::RemoteControl::Proxy::SSH;

use Moose;
with 'IRC::RemoteControl::Proxy';

use namespace::autoclean;
use Carp qw/croak/;

# requires libssh2 http://www.libssh2.org/
# Debian:   sudo aptitude install libssh2-1-dev
# OpenSUSE: sudo zypper in libssh2-1 libssh2-devel
use Net::SSH2;


has '_ssh' => (
    is => 'rw',
    builder => 'build_ssh_client',
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


sub build_ssh_client {
    my ($self) = @_;
    
    my $ssh;
    
    $ssh = Net::SSH2->new();
    #$ssh->blocking(1); why does this not work 8[]
    
    return $ssh;
}

around 'prepare' => sub {
    my ($orig, $self) = @_;
    
    my $ssh = $self->_ssh;
    
    # log in
    my $user = $self->username;
    my $pass = $self->password;
    my $ok;

    $ok = eval {
        $ssh->connect($self->proxy_address) or die $!;
        
        # should add key auth filenames here if needed
        if ( $ssh->auth(username => $user, password => $pass) ){
            # - logged in ok -

            # create channel from ssh host to irc server
            my $channel = $ssh->tcpip(
                $self->dest_address => $self->dest_port,
            );
            return unless $channel;
            
            $self->channel($channel);

            return 1;
        } else {
            # failed to log in
            return;
        }
    };
    warn $@ if $@;
    return if ($@ || ! $ok);
    
    # behave nicely
    $self->$orig();
    
    return 1;
};

# run forever
sub run {
    my ($self, $sock) = @_;
    
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
    
    $self->ready(0);
    $self->in_use(0);
    $self->clear_channel;
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
