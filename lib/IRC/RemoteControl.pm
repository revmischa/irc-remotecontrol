package IRC::RemoteControl;

# requires 5.10
use 5.010_000;
use feature "switch";

use Moose;
with 'MooseX::Getopt';
with 'IRC::RemoteControl::Proxy::Consumer';

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
    default => sub { 1 },
);

# ips available to bind to
has 'available_ips' => (
    is => 'rw',
    isa => 'ArrayRef',
    default => sub { [] },
);


# INTERNAL

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
}

sub load_proxies {
    my ($self) = @_;
    
    my $pp = IRC::RemoteControl::Proxy::Proxy->new_with_options(
        target_address      => $self->target_address,
        target_port         => $self->target_port,
        # ip_use_limit   => $self->ip_use_limit,
    );
    
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
    $self->available_ips(\@ips);
    
    print "Loaded " . (scalar @ips) . " from $ips_file\n";
}

sub generate_ipv6_list {
    my ($self) = @_;
    
    my $prefixes = $self->ipv6_prefixes;
    my $numips = $self->ipv6_tunnel_count;
    
    return unless @$prefixes && $numips;
    
    if ($> > 0) {
        warn "You are not running as root but have requested IPv6 tunnels be created. This will probably fail.\n";
    }
    
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
    		     `ifconfig gif0 inet6 $ip6 alias`;
    		     push @{ $self->created_tunnels }, $ip6;
    		 }
    	}
    }
}

sub slurp {
    my ($self, $filename) = @_;
    
    return unless $filename && -e $filename;
    
    my $slurp;
    my $fh;
    open $fh, $filename or die $!;
    {
        local $/;
        $slurp = <$fh>;
    }
    close $fh;
    
    return split(/\n/, $filename);
}

sub handle_command {
    my ($self, $cmd) = @_;
    
    my $h = $self->h;
    
    # strip whitespace
    $cmd =~ s/^(\s+)//;
    $cmd =~ s/(\s+)$//;
    
    given ($cmd) {
        when (/^(mass-)?spam(?:\s+(#\S+)\s+(.+))/i) {
            my ($mass, $chan, $text) = ($1, $2, $3);
            unless ($chan && $text) {
                return $h->push_write("Usage: spam #anxious MAN IN A DRESS HERE\n");
            }
        
            if ($mass) {
                $self->mass_spam($chan, $text);
            } else {
                $self->spam($chan, $text);
            }
        }
        
        when (/^stop/i) {
            $self->clients([]);
            return $h->push_write("Dereferencing connection handles...\n");
        }
        
        when (/^list( all)?/i) {
            my @proxies = $1 || ! $self->proxy_proxy ? @{ $self->proxies } : $self->available_proxies;
            
            foreach my $p (@proxies) {
                my $active;
                $active = $p->ok && $p->ready ? "Active" : "Inactive";
                
                $h->push_write("$active proxy: " . $p->description . "\n");
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
                "Available commands: spam, mass-spam, list, list all, stop\n");
        }
    }
}

sub get_random_proxy {
    my ($self) = @_;
    
    return unless $self->proxy_proxy && $self->available_proxies;
    
    return (shuffle $self->available_proxies)[0];
}

sub mass_spam {
    my ($self, $chan, $text) = @_;
    
    # unless ($self->available_ips) {
    #     $self->h->push_write("ERROR: you cannot use mass-spam until you have configured a list of bindable IPs\n");
    #     return;
    # }
    
    while ($self->spam($chan, $text)) {
        $self->h->push_write("Spamming $chan\n");
    }
}

# connect one bot and spam
sub spam {
    my ($self, $chan, $text) = @_;
    
    my $proxy = $self->get_random_proxy;
    return $self->connect($chan, $text, $proxy);
}

sub connect {
    my ($self, $chan, $text, $proxy) = @_;
    
    my $h = $self->h;

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
        $con->send_msg(JOIN => $chan);
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
        return unless $is_me;
        #$con->send_long_message(undef, 0, "PRIVMSG\001ACTION", $chan, $text);
        $con->send_long_message('utf-8', 0, "PRIVMSG", $chan, $text);
    });
    
    my $repeat_count = 1;
    
    $con->reg_cb(
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
                return 0;
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
    
    return 1;
}

sub DEMOLISH {
    my ($self) = @_;
        
    # bring down created tunnels
    if ($self->created_tunnels && @{ $self->created_tunnels } && $> == 0) {
        # slow
        `ifconfig gif0 inet6 $_ -alias` for @{ $self->created_tunnels };
        
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
