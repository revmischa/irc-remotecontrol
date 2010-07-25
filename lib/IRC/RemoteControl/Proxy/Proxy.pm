# This module is for creating a standalone proxy proxy, that is to say
# it can manage bringing proxy connections up and down and provide a
# standard interface to different proxy types.

package IRC::RemoteControl::Proxy::Proxy;

use Moose;
with 'IRC::RemoteControl::Proxy::Consumer';

use namespace::autoclean;

use IRC::RemoteControl::Proxy::SSH;
use IRC::RemoteControl::Proxy::SOCKS;
use IRC::RemoteControl::Proxy::Tunnel;
use IRC::RemoteControl::Util;

use AnyEvent::Socket;
use AnyEvent::Subprocess;
use AnyEvent::Handle;
use Socket;

# requires 5.10
use 5.010_000;
use feature "switch";

has 'target_address' => (
    is => 'rw',
    isa => 'Str',
    required => 0,
);

has 'target_port' => (
    is => 'rw',
    isa => 'Int',
);

has 'ip_use_limit' => (
    is => 'rw',
    isa => 'Int',
    default => sub { 1 },
);

# raw client (experimental)
has 'raw' => (
    is => 'rw',
    isa => 'Bool',
    default => 0,
);

# control server
has 'server' => (
    is => 'rw',
);

# control port bind address
has 'bind_address' => (
    is => 'rw',
    isa => 'Str',
    default => 'localhost',
);

# bind port
has 'bind_port' => (
    is => 'rw',
    isa => 'Str',
    default => '15909',
);

# control client connection handles
has 'listener_handles' => (
    is => 'rw',
    isa => 'ArrayRef',
    default => sub { [] },
);

# active tunnels
has 'tunnels' => (
    is => 'rw',
    isa => 'HashRef',
    default => sub { {} },
);

# active proxies
has 'proxies' => (
    is => 'rw',
    isa => 'ArrayRef',
    default => sub { [] },
);

# listen on control port for commands
sub begin {
    my ($self) = @_;
    
    $self->load_proxies;
    
    unless ($self->bind_address) {
        # bind to all
        return $self->bind_listener($self->bind_port);
    }
    
    AnyEvent::Socket::inet_aton $self->bind_address, sub {
        foreach my $addr (@_) {
            $self->bind_listener($self->bind_port, format_address $addr) and return;
        }
        
        die "Failed to bind to any ports for " . $self->bind_address . ", port " . $self->bind_port;
    };
}

sub available_proxies {
    my ($self, $type) = @_;
    
    my @avail = grep { $_->ok && ! $_->in_use } @{ $self->proxies };

    # filter by type
    if ($type) {
        @avail = grep { lc $_->type eq lc $type } @avail;
    }

    return @avail;
}

sub load_proxies {
    my ($self) = @_;
    
    my @proxies;

    foreach my $proxy_type (@{ $self->proxy_types }) {
        my $meth = "load_" . lc $proxy_type . "_proxies";
        push @proxies, $self->$meth;
    }
    
    foreach my $proxy (@proxies) {
        print "Loaded " . $proxy->description . "\n";
        
        # make multiple connections
        for (1 .. $self->ip_use_limit) {
            # bring up proxy connection
            $self->spawn_proxy_tunnel($proxy) or next;
            push @{ $self->proxies }, $proxy;
        }
    }
}

sub refresh_proxies {
    my ($self) = @_;
    
    foreach my $p (@{ $self->proxies }) {
        next if $p->auth_failed || $p->connecting || ! $p->ok;
        
        if (! $p->ready) {
            print "Refreshing " . $p->description . "\n";
            $p->reset;
            $self->spawn_proxy_tunnel($p);
        }
    }
}

sub fetch_proxies {
    my ($self, $type) = @_;
    
    unless (eval "use WWW::FreeProxyListsCom; 1;") {
        warn "WWW::FreeProxyListsCom is not installed, not fetching proxies\n";
        return ();
    }

    my $fetcher = WWW::FreeProxyListsCom->new;
    print "Fetching proxies from freeproxylists.com...\n";

    my $fetch_type = lc $type;
    $fetch_type = 'standard' if lc $type eq 'http';
    my $proxies = $fetcher->get_list(type => lc $fetch_type, max_pages => 2);
    unless ($proxies) {
        warn "Error fetching proxies: " . $fetcher->error . "\n";
        return ();
    }
    
    my @ret;
    foreach my $proxy (@$proxies) {
        my $ip = $proxy->{ip} or next;
        next unless $ip =~ /^\d+\.\d+\.\d+\.\d+/;
        my $p = $self->create_proxy($type, $ip, $proxy->{port});
        push @ret, $p;
    }

    return @ret;
}

sub load_socks_proxies {
    my ($self) = @_;
    
    my @proxies;
    
    push @proxies, $self->load_proxies_from_file('SOCKS');
    push @proxies, $self->fetch_proxies('SOCKS') if $self->fetch_socks_proxies;
    
    return @proxies;
}

sub load_http_proxies {
    my ($self) = @_;
    
    my @proxies;
    
    push @proxies, $self->load_proxies_from_file('HTTP');
    push @proxies, $self->fetch_proxies('HTTP') if $self->fetch_http_proxies;
    
    return @proxies;
}

sub load_https_proxies {
    my ($self) = @_;
    
    my @proxies;
    
    push @proxies, $self->load_proxies_from_file('HTTPS');
    push @proxies, $self->fetch_proxies('HTTPS') if $self->fetch_http_proxies;
    
    return @proxies;
}

sub load_ssh_proxies {
    my ($self) = @_;
    
    return $self->load_proxies_from_file('SSH');
}

sub load_proxies_from_file {
    my ($self, $type) = @_;
    
    my $filename = lc $type . '-proxies.txt';
    my @list = $self->load_file($filename) or return ();

    my @proxies;
    foreach my $line (@list) {
        next if $line =~ /^\s*#/; # skip comments
        
        my ($hostport, $username, $password) = split(/\s+/, $line);
        next unless $hostport;
        my ($host, $port) = AnyEvent::Socket::parse_hostport($hostport);
        
        unless ($host) {
            warn "Failed to load $type proxy $hostport - format must be host:port\n";
            next;
        }
        
        my $proxy = $self->create_proxy($type, $host, $port, $username, $password);
        push @proxies, $proxy if $proxy;
    }

    return @proxies;
}

sub load_file {
    my ($self, $filename) = @_;

    unless (-e $filename) {
        warn "$filename not found, skipping\n";
        return ();
    }
    
    my $slurp;
    my $fh;
    open $fh, $filename or die $!;
    {
        local $/;
        $slurp = <$fh>;
    }
    close $fh;
    
    return split(/\n/, $slurp);
}

sub bind_listener {
    my ($self, $service, $host) = @_;
    
    $host = undef if ! $host || $host =~ /^\s$/;  # bind to 0 or ::
    
    # create server for receiving commands
    my $server = tcp_server $host, $service, sub {
        my ($fh, $host, $port) = @_;

        # got connection
        my $hdl; $hdl = new AnyEvent::Handle
            fh => $fh,
            on_error => sub {
                my ($hdl, $fatal, $msg) = @_;
                warn "got error $msg\n";
            
                $hdl->destroy;
            },
            on_read => sub {
                $hdl->push_read('line', sub {
                    # read line
                    my (undef, $line) = @_;
                    
                    my $resp = $self->process_command($hdl, $line);
                });
            };
            
        push @{$self->listener_handles}, $hdl;
    };
    
    
    if ($server) {
        $self->server($server);
        $host ||= "(any IP)";
        print "Listening on $host, port $service\n";
    }
    
    return $server;
}

sub process_command {
    my ($self, $hdl, $input) = @_;
    
    # strip whitespace
    $input =~ s/^(\s*)//;
    $input =~ s/(\s*)$//sm;
    
    my ($command, $args_str) = $input =~ /^(\w+)\s*(.*)$/sm;
    $args_str ||= '';
    my @args = split(/\s+/, $args_str);
    return unless $command;
    
    given ($command) {
        # write raw data through all active proxies
        when ('write') {
            $self->process_command_write($hdl, "$args_str\r\n");
        }
        
        # spawn proxy
        when ('proxy') {
            $self->process_command_proxy($hdl, @args);
        }

        default {
            $hdl->push_write("Unknown command \"$command\"\n");
        }
    }
}

# write raw data through all active proxies
sub process_command_write {
    my ($self, $data) = @_;
    
    # write to all active tunnels
    foreach my $p ($self->available_proxies) {
        $p->tunnel->write($data);
    }
}

sub process_command_proxy {
    my ($self, $hdl, $type_in, $host, $port, $username, $password) = @_;

    unless ($type_in) {
        $hdl->push_write("No proxy type specified\n");
        return;
    }

    unless ($host) {
        $hdl->push_write("No host name specified\n");
        return;
    }
    
    my $type;
    given (lc $type_in) {
        when ('ssh') {
            $type = 'SSH';
        }
        
        default {
            $hdl->push_write("Unknown proxy type $type_in\n");
            return;
        }
    }

    my $proxy = $self->create_proxy($type, $host, $port, $username, $password);
    $hdl->push_write("Attempting to bring up " . $proxy->description . "...\n");
    
    $self->spawn_proxy_tunnel($proxy, $hdl);
}

sub spawn_proxy_tunnel {
    my ($self, $proxy, $hdl) = @_;

    return 1 unless $proxy->needs_tunnel;
    
    return $self->spawn_tunnel($proxy, sub {
        my $status = shift;
        $status = $proxy->description . " status: $status.\n";
        
        if ($hdl) {
            $hdl->push_write($status);
        } else {
            print $status;
        }
    });
}

sub create_proxy {
    my ($self, $type, $host, $port, $username, $password) = @_;
    
    my %opts = (
        proxy_address => $host,
        type => $type,
    );

    $opts{dest_address} = $self->target_address if $self->target_address;
    $opts{proxy_port} = $port if defined $port;
    $opts{username} = $username if defined $username;
    $opts{password} = $password if defined $password;
    $opts{dest_port} = $self->target_port if defined $self->target_port;
    
    eval "use IRC::RemoteControl::Proxy::$type; 1;" or die $@;
    my $proxy = "IRC::RemoteControl::Proxy::$type"->new(%opts);
    return $proxy;
}

sub spawn_tunnel {
    my ($self, $proxy, $status_callback) = @_;
    
    my $started = 0;
    my $tunnel;
    my $proc;
    
    $proxy->clear_tunnel;
    $proxy->connecting(1);
    
    my $subproc = AnyEvent::Subprocess->new(
        delegates     => [qw/StandardHandles CommHandle/],
        code          => sub {
            my $args = shift;
            my $comm_socket_fh = $args->{comm};

            my $ok = $proxy->prepare;
            print(($ok ? "OK" : "FAILED") . "\n");
            
            if ($ok && $comm_socket_fh) {
                eval {
                    my $comm_socket = AnyEvent::Handle->new( fh => $comm_socket_fh );
                    $proxy->comm_handle_fh($comm_socket_fh);
                    $comm_socket_fh->autoflush;
                    
                    # data read from tunnel
                    $proxy->on_read(sub {
                        my $line = shift;
                        $comm_socket_fh->write($line);
                    });

                    $comm_socket->on_error(sub {
                        my ($hdl, $fatal, $msg) = @_;
                        warn "Child tunnel handler for $proxy lost communication socket with parent\n";
                        $hdl->destroy;

                        exit;
                    });

                    if ($self->raw) {
                        my $nick = IRC::RemoteControl::Util->gen_nick;
                        my $user = IRC::RemoteControl::Util->gen_user;
                        my $real = IRC::RemoteControl::Util->gen_real;
                    
                        $proxy->write("NICK $nick\r\n");
                        $proxy->write("USER $user $nick $nick :$real\r\n");
                    }

                    print "READY\n";
                    
                    if (! eval { $proxy->run($comm_socket_fh) }) {  # blocks until completion
                        my $errstr = "ERROR";
                        $errstr .= ": $@" if $@;
                        print "$errstr\n";
                    }
                };  
                
                warn $@ if $@;
                
                exit 0;
            }
        },
        on_completion => sub {
            my $child = shift;
            
            $proxy->reset;
                
            if ($started) {
                $status_callback->("closed");
            }
            if ($tunnel) {
                delete $self->tunnels->{$tunnel->id};
                $proxy->clear_tunnel;
            }
        },
    );
    
    $proc = $subproc->run;
    
    my $comm_handle = $proc->delegate('comm')->handle;
    $proxy->comm_handle($comm_handle);
    
    # handle sub-process errors
    $proc->delegate('stderr')->handle->on_read(sub {
        my ($hdl) = @_;
        $hdl->push_read(line => sub {
            my (undef, $line) = @_;
            $status_callback->("ERROR: $line");
        });
    });
    
    # handle data read from tunnel (if raw client mode)
    if ($self->raw) {
        $proc->delegate('comm')->handle->on_read(sub {
            my ($hdl) = @_;
            $hdl->push_read(line => sub {
                my (undef, $line) = @_;
                return unless $line;
            
                $line =~ s/^(\s+)//;
                $line =~ s/(\s+)$//;
            
                if (my ($ping) = $line =~ /^PING :(.+)$/) {
                    $hdl->push_write("PONG :$ping\r\n");
                }
            
                $status_callback->("READ LINE: $line");
            });
        });
    }

    $tunnel = new IRC::RemoteControl::Proxy::Tunnel(
        subprocess => $proc,
        proxy => $proxy,
        type => $proxy->type,
    );
    $proxy->tunnel($tunnel);

    # handle status updates from tunnel creation
    $proc->delegate('stdout')->handle->on_read(sub {
        my ($hdl) = @_;
        $hdl->push_read(line => sub {
            my (undef, $line) = @_;
            
            $status_callback->("$line");
            if ($line && uc $line eq 'OK') {
                # tunnel now active...
                $started = 1;
                $proxy->connecting(0);
                $proxy->ok(1);
                $proxy->retried(0);
                $self->tunnels->{$tunnel->id} = $tunnel;
            } elsif ($line && uc $line eq 'ERROR') {
                $started = 0;
                $proxy->reset;
                $proxy->ok(0);
            } elsif ($line && uc $line eq 'FAILED') {
                $started = 0;
                $proxy->reset;
                $proxy->ok(0) if $proxy->retried > 3;
                $proxy->retried($proxy->retried + 1);
            } elsif ($line && uc $line eq 'AUTH_FAILED') {
                $proxy->auth_failed(1);
                $proxy->ready(0);
                $proxy->ok(0);
            } elsif ($line && uc $line eq 'READY') {
                $started = 1;
                $proxy->ready(1);
                $proxy->retried(0);
            } else {
                $line ||= 'undef';
                $proxy->ok(0);
                $status_callback->("got unknown status: $line");
            }
        });
    });
}

# get all active tunnels, optionally filtered by $type
sub all_tunnels {
    my ($self, $type) = @_;
    
    my @tunnels = values %{$self->tunnels};
    @tunnels = grep { $_->type eq $type } @tunnels if $type;
    
    return @tunnels;
}

__PACKAGE__->meta->make_immutable;
