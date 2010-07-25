package IRC::RemoteControl;

# requires 5.10
use 5.010_000;
use feature "switch";

use Moose;
    with 'MooseX::Getopt';
    with 'IRC::RemoteControl::Proxy::Consumer';

use Moose::Util;
use AnyEvent;
use AnyEvent::Socket;
use AnyEvent::Handle;
use AnyEvent::IRC;
use List::Util qw/shuffle/;

use IRC::RemoteControl::Proxy::Proxy;
use IRC::RemoteControl::Util;

our $VERSION = '0.03';

# proxy required to connect
has 'require_proxy' => (
    is => 'rw',
    isa => 'Bool',
    default => 0,
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
    default => sub { 1 },
);

has 'repeat_count' => (
    is => 'rw',
    isa => 'Int',
    default => sub { 5 },
);

# ips available to bind to
has 'available_ips' => (
    is => 'rw',
    isa => 'ArrayRef',
    default => sub { [] },
);

has 'personalities' => (
    is => 'rw',
    isa => 'ArrayRef',
    lazy => 1,
    builder => 'build_personalities',
);

has 'tunnel_device' => (
    is => 'rw',
    isa => 'Str',
    builder => 'build_tunnel_device',
    lazy => 1,
);

# methods for personalities
sub registered { my ($self, $conn) = @_; }  # connected to IRC server, ready to send commands
sub joined { my ($self, $conn, $nick, $chan, $is_me) = @_; }  # $nick joined $chan

# register a client command
sub register_command {
    my ($self, $command, $callback) = @_;

    push @{$self->known_commands}, $command;
    $self->registered_commands->{$command} = $callback;
}

# there is where personalities should register commands and do any other initialization
sub setup { my ($self) = @_ }

####

sub build_personalities {
    return [qw/Flood/];
}

# call this to start the server
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
                        eval {
                            $self->handle_command($line);
                        };
                        if ($@) {
                            $handle->push_write("Error executing command: $@");
                        }
                    },
                );
            };
            
        $self->server_handle($handle);
        $handle->push_write('- Welcome to ' . __PACKAGE__ . " -\n");
    } or die $!;
    
    print "Listening on $bind_ip:$bind_port\n";
    $self->listen_server($server);
    
    $self->load_available_ips;
    $self->load_proxies if $self->use_proxy;
    
    if (@{ $self->ipv6_prefixes }) {
        $self->generate_ipv6_list;
    }

    # compose personalities into this instance
    my @personalities = map { __PACKAGE__ . "::Personality::$_" } @{ $self->personalities };
    Moose::Util::ensure_all_roles($self, @personalities);

    # tells personalities to do their setup
    $self->setup;
}

### everything else below is internal, you should not need to use any of it

# control socket clients
has clients => ( 
    is => 'rw',
    isa => 'ArrayRef',
    default => sub { [] },
    traits => [ 'NoGetopt' ],
);

# control socket handle
has 'server_handle' => (
    is => 'rw',
    traits => [ 'NoGetopt' ],
);

# more commands registered from plugins
has 'registered_commands' => (
    is => 'rw',
    traits => [ 'NoGetopt' ],
    isa => 'HashRef',
    default => sub { {} },
);

# main loop
has 'cv' => (
    is => 'rw',
    traits => [ 'NoGetopt' ],
);

has 'proxy_refresh_timer' => (
    is => 'rw',
    clearer => 'clear_proxy_refresh_timer',
    traits => [ 'NoGetopt' ],
);

# control socket
has 'listen_server' => (
    is => 'rw',
    traits => [ 'NoGetopt' ],
);

has 'created_tunnels' => (
    is => 'rw',
    isa => 'ArrayRef',
    traits => [ 'NoGetopt' ],
    default => sub { [] },
    lazy => 1,
);

# map of ip -> client_count
has 'used_ips' => (
    is => 'rw',
    isa => 'HashRef',
    traits => [ 'NoGetopt' ],
    default => sub { {} },
);

# proxy-proxy, a proxy manager responsible for 
# bringing up tunnels and verifying proxies
has 'proxy_proxy' => (
    is => 'rw',
    isa => 'IRC::RemoteControl::Proxy::Proxy',
    traits => [ 'NoGetopt' ],
    handles => [qw/proxies available_proxies refresh_proxies/],
);

has 'known_commands' => (
    is => 'rw',
    isa => 'ArrayRef',
    default => sub { ['list', 'list all', 'stop'] },
);

*h = \&server_handle;

sub load_proxies {
    my ($self) = @_;

    return unless @{$self->proxy_types};

    # need to copy attributes from Proxy::Consumer
    my $pp_attr = {};
    my @consumer_attrs = IRC::RemoteControl::Proxy::Consumer->meta->get_attribute_list;
    $pp_attr->{$_} = $self->$_
        for (@consumer_attrs);

    my $pp = IRC::RemoteControl::Proxy::Proxy->new(%$pp_attr);
    
    $pp->load_proxies;
    $self->proxy_proxy($pp);
    
    # periodically refresh proxies
    my $w = AnyEvent->timer (
        after    => 5,
        interval => 2,
        cb       => sub { $self->refresh_proxies },
    );
    $self->proxy_refresh_timer($w);
}

sub load_available_ips {
    my ($self) = @_;
    
    my $ips_file = "ips.txt";
    return unless $ips_file;
    
    my @ips = $self->slurp($ips_file) or return;

    # filter out junk/comments
    my @newips;
    foreach my $line (@ips) {
        $line =~ s/(#.*)$//;
        next unless $line =~ /\w+/;
        push @newips, $line;
    }

    $self->available_ips(\@newips);
    
    print "Loaded " . (scalar @newips) . " from $ips_file\n";
}

# default ipv6 tunnel device
sub build_tunnel_device {
    my ($self) = @_;

    my $os = $self->get_os;
    my $dev;

    if ($os eq 'linux') {
        $dev = 'he-ipv6';
    } elsif ($os eq 'freebsd' || $os eq 'darwin') {
        $dev = 'gif0';
    }

    return $dev;
}

sub generate_ipv6_list {
    my ($self) = @_;
    
    my $prefixes = $self->ipv6_prefixes;
    my $numips = $self->ipv6_tunnel_count;
    
    return unless @$prefixes && $numips;
    
    if ($> > 0) {
        warn "You are not running as root but have requested IPv6 tunnels be created. This will probably fail.\n";
    }

    my $dev = $self->tunnel_device;
    my $os = $self->get_os;

    foreach my $prefix (@$prefixes) {
    	for (my $j = 0; $j < $numips; $j++) {
            my @prefwords =  split(':', $prefix);
            for (my $i = $#prefwords + 1; $i < 8; $i++) {
                push(@prefwords, sprintf("%x",int(rand(hex("ffff")))))
            }
            
            my $ip6 = join(':', @prefwords);
            push @{ $self->available_ips }, $ip6;
            
            if ($self->debug) {
                print "Generating tunnel IP $ip6\n";
            }
            
            # bring up IP
            if ($> == 0) {
                # create tunnel if EUID == root
                if ($os eq 'linux') {
                    `ip addr add $ip6 dev $dev`;  # linuxe
                } elsif ($os eq 'freebsd' || $os eq 'darwin') {
                    `ifconfig $dev inet6 $ip6 alias`;  # bsd
                } else {
                    warn "I don't know how to create ipv6 tunnels for $os";
                }

                push @{ $self->created_tunnels }, $ip6;
            }
    	}
    }
}

sub get_os {
    my $os = `uname -s`;
    chomp $os;
    $os = lc $os;
    return $os;
}

sub slurp {
    my ($self, $filename) = @_;
    
    return unless $filename && -e $filename;
    
    my $slurp;
    my $fh;
    open $fh, $filename or die $!;
    my @ret;
    while (my $line = <$fh>) {
        push @ret, $line;
    }
    close $fh;
    
    return @ret;
}

sub handle_command {
    my ($self, $cmd) = @_;
    
    my $h = $self->h;
    
    # strip whitespace
    $cmd =~ s/^(\s+)//;
    $cmd =~ s/(\s+)$//;

    my $registered_commands = $self->registered_commands;
    my ($first_word, $args) = $cmd =~ m/^([\w-]+)\s?(.*)$/;
    return unless $first_word;

    $args =~ s/^(\s+)//;
    $first_word =~ s/(\s+)$//;

    my $cb = $registered_commands->{$first_word};

    # found callback for command
    if ($cb) {
        return $cb->($self, $h, $first_word, $args);
    }
    
    given ($cmd) {
        when (/^stop/i) {
            $self->clients([]);
            return $h->push_write("Dereferencing connection handles...\n");
        }
        
        when (/^list( all)?/i) {
            if ($self->proxy_proxy) {
                my @proxies = $1 ? @{ $self->proxies } : $self->available_proxies;
            
                foreach my $p (@proxies) {
                    my $active;
                    $active = $p->ok && $p->ready ? "Active" : "Inactive";
                
                    $h->push_write("$active proxy: " . $p->description . "\n");
                }
            }

            foreach my $ip (@{ $self->available_ips }) {
                $h->push_write("Source IP $ip\n");
            }
        }
        
        when (/^write (.+)/) {
            if ($self->proxy_proxy) {
                $self->proxy_proxy->process_command_write($1);
            } else {
                return $h->push_write("No proxies available to write to.\n");
            }
        }
        
        default {
            break unless $cmd;
            
            return $h->push_write("Unknown command '$cmd'. " .
                "Available commands: " . join(', ', @{$self->known_commands}) . "\n");
        }
    }
}

sub get_random_proxy {
    my ($self, $type) = @_;
    
    return unless $self->proxy_proxy && $self->available_proxies($type);
    
    return (shuffle $self->available_proxies($type))[0];
}

sub connect {
    my ($self, $chan, $text, $proxy) = @_;
    
    my $h = $self->h;

    unless ($self->target_address) {
        $h->push_write("Attempting to connect but no target specified\n");
        return;
    }

    if (! $proxy && $self->require_proxy && $self->use_proxy) {
        $h->push_write("No active proxies found and require_proxy=1\n");
        return;
    }
                
    my $con = $proxy ? AnyEvent::IRC::Client::Proxy->new : AnyEvent::IRC::Client::Pre->new;
    my $viaproxy = $proxy ? " via proxy " . $proxy->description : '';

    my $bind_ip;

    $con->reg_cb(connect => sub {
        my ($con, $err) = @_;
        
        if (defined $err) {
            $h->push_write("Error connecting to " . $self->target_address . "$viaproxy: $err\n");
            my @new_clients = grep { $_ != $con } @{$self->clients};
            $self->clients(\@new_clients);
            return;
        }
        
        $h->push_write("Connected to " . $self->target_address . "$viaproxy\n");
    });
    
    $con->reg_cb(registered => sub {
        $h->push_write("Registered @ " . $self->target_address . "$viaproxy\n");
        $self->registered($con);
    });
    
    $con->reg_cb(disconnect => sub {
        $h->push_write("Disconnected from " . $self->target_address . "$viaproxy\n");
        $proxy->reset if $proxy;
        
        $self->used_ips->{$bind_ip}-- if $bind_ip;
        my @new_clients = grep { $_ != $con } @{$self->clients};
        $self->clients(\@new_clients);
    });
    
    $con->reg_cb(join => sub {
        my (undef, $nick, $chan, $is_me) = @_;
        $self->joined($con, $nick, $chan, $is_me);
    });    

    my $nick = IRC::RemoteControl::Util->gen_nick;
    my $user = IRC::RemoteControl::Util->gen_user;
    my $real = IRC::RemoteControl::Util->gen_real;
    
    if ($proxy) {
        $con->proxy_connect($proxy, $self->debug, $nick, $user, $real);
    } else {
        # pick an ip to bind to
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
                return;
            }
        }
    
        my $connect_addr = $self->target_address;
        my $connect_port = $self->target_port;
    
        $con->connect($connect_addr, $connect_port, { nick => $nick, user => $user, real => $real }, sub {
            my ($fh) = @_;
    
            if ($bind_ip) {
                my $bind = AnyEvent::Socket::pack_sockaddr(undef, parse_address($bind_ip));
                bind $fh, $bind;
            }
        
            return $self->connect_timeout;
        });
    }
    
    $con->{proxy} = $proxy;
    push @{$self->clients}, $con;
    
    return $con;
}

sub DEMOLISH {
    my ($self) = @_;
        
    # bring down created tunnels
    if ($self->created_tunnels && @{ $self->created_tunnels } && $> == 0) {
        # slow
        my $os = $self->get_os;

        my $command;
        my $dev = $self->tunnel_device;
        if ($os eq 'linux') {
            $command = "ip addr del %s dev $dev";
        } elsif ($os eq 'freebsd' || $os eq 'darwin') {
            $command = "ifconfig $dev inet6 %s -alias";
        }

        if ($command) {
            foreach my $ip (@{ $self->created_tunnels }) {
                my $cmd = sprintf($command, $ip);
                `$cmd`;
            }
        } else {
            warn "Don't know how to bring down tunnels on $os";
        }
        
        # faster, deletes everything though, hope you dont care!
        # doesn't work on osx
        # fix this plz
        #`ifconfig gif0 destroy`;
    }
}

no Moose;
__PACKAGE__->meta->make_immutable;



# IRC client using an existing handle for communication
# super ghetto hack below
package AnyEvent::IRC::Client::Proxy;

use strict;
use warnings;

use parent 'AnyEvent::IRC::Client';

sub proxy_connect {
    my ($self, $proxy, $debug, $nick, $user, $real) = @_;
    
    unless ($proxy && $proxy->comm_handle) {
        $self->event(connect => "No proxy or communication handle found, aborting proxy_connect()");
        return;
    }
    
    if ($proxy->in_use) {
        $self->event(connect => "Proxy is in use");
        return;
    }

    if ($self->{socket}) {
        $self->disconnect("reconnect requested.");
    }
    
    $proxy->in_use(1);
    
    $self->{host} = $proxy->dest_address;
    $self->{port} = $proxy->dest_port;
    
    $self->{socket} = $proxy->comm_handle;
    $proxy->comm_handle->on_read(sub {
        return unless $proxy->comm_handle;
        
        $proxy->comm_handle->push_read(line => sub {
            my ($h, $line) = @_;
            
            if ($debug) {
                print ">> $line\n";
            }
            
            $self->_feed_irc_data($line);
        });
    });
    
    $proxy->comm_handle->on_drain(sub {
        $self->event('buffer_empty');
    });
    
    $self->{register_cb_guard} = $self->reg_cb(
        ext_before_connect => sub {
            my ($self, $err) = @_;

            unless ($err) {
                $self->register($nick, $user, $real);
            }

            delete $self->{register_cb_guard};
        }
    );
    
    $self->event('connect');
}

1;




# silly hack to let us use a prebinding callback
# i think they fixed it so this is no longer needed
package AnyEvent::IRC::Client::Pre;

use strict;
use warnings;
use AnyEvent::IRC::Connection;

use parent 'AnyEvent::IRC::Client';

sub connect {
    my ($self, $host, $port, $info, $pre) = @_;

    if (defined $info) {
        $self->{register_cb_guard} = $self->reg_cb(
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


    See README for more information.


=head1 DESCRIPTION

This project aims to bring a new level of professionalism and stable
code to the world of remote-control IRC. It has a modular design,
allowing reuse of different proxy and personality types.

=head2 EXPORT

None by default.

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
