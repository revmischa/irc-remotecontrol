package IRC::RemoteControl;

use Moose;
use AnyEvent;
use AnyEvent::Socket;
use AnyEvent::Handle;
use List::Util qw/shuffle/;

our $VERSION = '0.01';

has clients => (
    is => 'rw',
    isa => 'ArrayRef',
    default => sub { [] },
);

has 'server_handle' => (
    is => 'rw',
);

has 'cv' => (
    is => 'rw',
);

has 'listen_server' => (
    is => 'rw',
);

has 'connect_timeout' => (
    is => 'rw',
    isa => 'Int',
    default => sub { 10 },
);

has 'server_bind_ip' => (
    is => 'rw',
    isa => 'Str',
    default => sub { '127.0.0.1' },
);

has 'server_bind_port' => (
    is => 'rw',
    isa => 'Int',
    default => sub { 1488 },
);

# how many connections per source ip
has 'ip_use_limit' => (
    is => 'rw',
    isa => 'Int',
    default => sub { 2 },
);

has 'repeat_count' => (
    is => 'rw',
    isa => 'Int',
    default => sub { 20 },
);

# ips available to bind to
has 'available_ips' => (
    is => 'rw',
    isa => 'ArrayRef',
);

# map of ip -> client_count
has 'used_ips' => (
    is => 'rw',
    isa => 'HashRef',
    default => sub { {} },
);

*h = \&server_handle;

sub start {
    my ($self) = @_;
    
    my $bind_ip = $self->server_bind_ip;
    my $bind_port = $self->server_bind_port;
    
    my $server = tcp_server $bind_ip, $bind_port, sub {
        my ($fh, $rhost, $rport) = @_;
        
        print "Connection from $rhost:$rport\n";
        my $handle; $handle = new AnyEvent::Handle
            fh => $fh,
            on_eof => sub {
                # should disconnect all clients
                $self->used_ips({});
                $self->clients([]);
            },
            on_error => sub {
                my (undef, $fatal, $msg) = @_;
                warn "Got fatal error on server socket: $msg";
                $handle->destroy;
                undef $handle;
                $self->cv->send if $self->cv;
            },
            on_read => sub {
                $handle->push_read(
                    line => sub {
                        my (undef, $line) = @_;
                        print " >> $line\n";
                        $self->handle_command($line);
                    },
                );
            };
            
        $self->server_handle($handle);
        $handle->push_write('- Welcome to ' . __PACKAGE__ . " -\n");
    } or die $!;
    
    print "Listening on $bind_ip:$bind_port\n";
    
    $self->listen_server($server);
}

sub handle_command {
    my ($self, $cmd) = @_;
    
    my $h = $self->h;
    
    $cmd =~ s/^\s*//;
    
    if ($cmd =~ m/^(mass-)?spam(?: (\S+)\s+(#\S+)\s+(.+))/i) {
        my ($mass, $server, $chan, $text) = ($1, $2, $3, $4);
        unless ($server && $chan && $text) {
            return $h->push_write("Usage: spam irc.he.net #anxious MAN IN A DRESS HERE\n");
        }
        
        if ($mass) {
            $self->mass_spam($server, $chan, $text);
        } else {
            $self->spam($server, $chan, $text);
        }
    } elsif ($cmd =~ m/^stop/i) {
        $self->clients([]);
        return $h->push_write("Dereferencing connection handles...\n");
    } else {
        return $h->push_write("Unknown command '$cmd'. Available commands: spam, mass-spam, stop\n");
    }
}

sub mass_spam {
    my ($self, $server, $chan, $text) = @_;
    
    unless ($self->available_ips) {
        $self->h->push_write("ERROR: you cannot use mass-spam until you have configured a list of bindable IPs\n");
        return;
    }
    
    while ($self->spam($server, $chan, $text)) {
        $self->h->push_write("Connecting to $server\n");
    }
}

# connect one bot and spam
sub spam {
    my ($self, $server, $chan, $text) = @_;
    
    my $h = $self->h;
    
    # pick an ip to bind to
    my $bind_ip = undef;
    if ($self->available_ips) {
        my $passes;
        LIMIT: foreach my $pass (1 .. $self->ip_use_limit) {
            foreach my $ip (@{$self->available_ips}) {
                next if $self->used_ips->{$ip} && $self->used_ips->{$ip} >= $pass;
                $bind_ip = $ip;
                $self->used_ips->{$ip}++;
                last LIMIT;
            }
            
            $passes++;
        }
        
        unless ($bind_ip) {
            $h->push_write("Used up all available IPs $passes time" . ($passes == 1 ? '' : 's') . "\n");
            return 0;
        }
    }
        
    my $con = new AnyEvent::IRC::Client::Pre;

    $con->reg_cb(connect => sub {
        my ($con, $err) = @_;
        
        if (defined $err) {
            $h->push_write("Error connecting to $server: $err\n");
            my @new_clients = grep { $_ != $con } @{$self->clients};
            $self->clients(\@new_clients);
            return;
        }
        
        $h->push_write("Connected to $server\n");
    });
    
    $con->reg_cb(registered => sub {
        $h->push_write("Registered @ $server\n");
        $con->send_msg(JOIN => $chan);
    });
    
    $con->reg_cb(disconnect => sub {
        $h->push_write("Disconnected from $server\n");
        $self->used_ips->{$bind_ip}-- if $bind_ip;
        my @new_clients = grep { $_ != $con } @{$self->clients};
        $self->clients(\@new_clients);
    });
    
    $con->reg_cb(join => sub {
        my (undef, $nick, $chan, $is_me) = @_;
        return unless $is_me;
        #$con->send_long_message(undef, 0, "PRIVMSG\001ACTION", $chan, $text);
        $con->send_long_message('utf-8', 0, "PRIVMSG", $chan, $text);
    });
    
    my $repeat_count = 1;
    
    $con->reg_cb (
        sent => sub {
            my ($con) = @_;

            if ($_[2] eq 'PRIVMSG') {
                $con->{timer_} = AnyEvent->timer(
                    after => 0.8,
                    cb => sub {
                        delete $con->{timer_};
                        if ($repeat_count++ >= $self->repeat_count) {
                            $con->disconnect;
                        } else {
                            $con->send_long_message('utf-8', 0, "PRIVMSG", $chan, $text);
                        }
                    },
                );
            }
        }
    );

    my $nick = $self->gen_nick;
    my $b = $bind_ip;
    $con->connect($server, 6667, { nick => $nick, user => $nick, real => $nick }, sub {
        my ($fh) = @_;

        if ($bind_ip) {
            my $bind = AnyEvent::Socket::pack_sockaddr(undef, parse_address($bind_ip));
            bind $fh, $bind;
        }
        
        return $self->connect_timeout;
    });
    
    push @{$self->clients}, $con;
    return 1;
}

sub gen_nick {
    # offensive words
    my @words = qw/gouda gapp pump randi yahoo poop dongs anus goat peepee
        blog mugu jenkem grids aids hiv crack gay hitler wpww jre msi
        toot gas perl python php gapp gouda tron gouda tron gouda flouride
        stock broker bull bear market gsax bond gold silver gold ivest
        mkt hedge linden dsp asi grim flaccid jenk gas moot max lol nog
        flooz stax spin hard rock yid monger spleen pre oro smack jim bob
        mugabe spliff jay ngr lips skeet horse horsey crunk stunnas bleez
        pump lyfe mop irc die death log fubu racewar rahowa nwo/;

    my @wordlist = (shuffle @words)[0..int(rand(2) + 1)];

    my $nick = '';

    foreach my $word (@wordlist) {
        $word = ucfirst $word if int(rand(10)) < 5;
        $nick .= '_' if $nick && int(rand(10)) < 2;
        $nick .= $word;
    }

    $nick = substr($nick, 0, 8); # symbols max

    return $nick;
}


no Moose;
__PACKAGE__->meta->make_immutable;

# silly hack to let us use a prebinding callback
package AnyEvent::IRC::Client::Pre;

use strict;
use warnings;
use AnyEvent::IRC::Connection;

use parent 'AnyEvent::IRC::Client';

sub connect {
   my ($self, $host, $port, $info, $pre) = @_;

  if (defined $info) {
     $self->{register_cb_guard} = $self->reg_cb (
        ext_before_connect => sub {
           my ($self, $err) = @_;

           unless ($err) {
              $self->register(
                 $info->{nick}, $info->{user}, $info->{real}, $info->{password}
              );
           }

           delete $self->{register_cb_guard};
        }
     );
  }
  
  AnyEvent::IRC::Connection::connect($self, $host, $port, $pre);
}

1;
__END__

=head1 NAME

IRC::RemoteControl - Simple daemon for proxying irc connections

=head1 SYNOPSIS

    use IRC::RemoteControl;
    use AnyEvent;
    use List::Util qw/shuffle/;

    my $main = AnyEvent->condvar;

    my @ips;
    for my $i (131 .. 226) {
    	push @ips, "123.45.67.$i";
    }
    @ips = shuffle @ips;

    my $rc = new IRC::RemoteControl(
        cv => $main,
        available_ips => \@ips,
        ip_use_limit => 4, # how many connections per source IP
        connect_timeout => 15,
        server_bind_port => 1_488,
        server_bind_ip => '127.0.0.1',
        
    );
    $rc->start;
    
    $main->recv;

=head1 DESCRIPTION

This project aims to bring a new level of professionalism and stable code to the world of remote-control IRC.

=head2 EXPORT

None by default.


=head1 HISTORY

=over 8

=item 0.01

Original version; created by h2xs 1.23 with options

  -n
	IRC::RemoteControl
	-A
	-C
	-X
	-c

=back



=head1 SEE ALSO

http://code.google.com/p/irc-remotecontrol

=head1 AUTHOR

Thaddeus Wooster, E<lt>wooster@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2010 by Thaddeus Wooster

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.10.0 or,
at your option, any later version of Perl 5 you may have available.


=cut
