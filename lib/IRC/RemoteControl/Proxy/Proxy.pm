# This module is for creating a standalone proxy proxy, that is to say
# it can manage bringing proxy connections up and down and provide a
# standard interface to different proxy types.

package IRC::RemoteControl::Proxy::Proxy;

use Moose;

use namespace::autoclean;
use Data::Dumper;

use IRC::RemoteControl::Proxy::SSH;
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
    required => 1,
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

has 'subprocs' => (
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
    my ($self) = @_;
    
    return grep { $_->ready && ! $_->in_use } @{ $self->proxies };
}

sub load_proxies {
    my ($self) = @_;
    
    my @proxies;

    push @proxies, $self->load_ssh_proxies;
    
    foreach my $proxy (@proxies) {
        # bring up proxy connection
        $self->spawn_tunnel($proxy, sub {
            my $status = shift;
            print $proxy->type . " tunnel via " . $proxy->proxy_address . " status: $status\n";
            
            if (lc $status eq 'ok') {
                push @{ $self->proxies }, $proxy;
            }
        });
    }
}

sub load_ssh_proxies {
    my ($self) = @_;
    
    my @list = $self->load_file('ssh-proxies.txt');
    
    my @proxies;
    foreach my $line (@list) {
        next if $line =~ /^\s*#/; # skip comments
        
        my ($hostport, $username, $password) = split(/\s+/, $line);
        next unless $hostport;
        my ($host, $port) = AnyEvent::Socket::parse_hostport($hostport);
        
        unless ($host) {
            warn "Failed to load SSH proxy $hostport - format must be host:port\n";
            next;
        }
        
        my $proxy = $self->create_proxy('SSH', $host, $port, $username, $password);
        push @proxies, $proxy;
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
    foreach my $tunnel ($self->all_tunnels) {
        $tunnel->write($data);
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
    $hdl->push_write("Attempting to bring up $type tunnel for " . $proxy->description . "...\n");
    
    return $self->spawn_tunnel($proxy, sub {
        my $status = shift;
        $hdl->push_write("$type tunnel for $host status: $status.\n");
    });
}

sub create_proxy {
    my ($self, $type, $host, $port, $username, $password) = @_;
    
    my %opts = (
        proxy_address => $host,
        dest_address => $self->target_address,
    );
    $opts{proxy_port} = $port if defined $port;
    $opts{username} = $username if defined $username;
    $opts{password} = $password if defined $password;
    $opts{dest_port} = $self->target_port if defined $self->target_port;
    
    my $proxy = "IRC::RemoteControl::Proxy::$type"->new(%opts);
    return $proxy;
}

sub spawn_tunnel {
    my ($self, $proxy, $status_callback) = @_;
    
    my $started = 0;
    my $tunnel;
    my $proc; $proc = AnyEvent::Subprocess->new(
        delegates     => [qw/StandardHandles CommHandle/],
        code          => sub {
            my $args = shift;
            my $comm_socket_fh = $args->{comm};
            
            my $ok = $proxy->prepare;
            print(($ok ? "OK" : "FAILED") . "\n");
            
            if ($ok) {
                eval {                    
                    my $comm_socket = AnyEvent::Handle->new( fh => $comm_socket_fh );
                    $proxy->comm_handle_fh($comm_socket_fh);
                    $comm_socket_fh->autoflush;
                    
                    if ($self->raw) {
                        my $nick = IRC::RemoteControl::Util->gen_nick;
                        my $user = IRC::RemoteControl::Util->gen_user;
                        my $real = IRC::RemoteControl::Util->gen_real;
                    
                        $proxy->write("NICK $nick\r\n");
                        $proxy->write("USER $user $nick $nick :$real\r\n");
                    }
                    
                    # data read from tunnel
                    $proxy->on_read(sub {
                        my $line = shift;
                        $comm_socket_fh->write($line);
                    });
                    
                    $proxy->run($comm_socket_fh);  # blocks until completion
                };  
                
                warn $@ if $@;
                
                exit 0;
            }
        },
        on_completion => sub {
            my $child = shift;
            
            $proxy->clear_comm_handle;
            $proxy->clear_comm_handle_fh;
                
            if ($started) {
                $status_callback->("closed");
            }
            if ($tunnel) {
                delete $self->tunnels->{$tunnel->id};
            }
        },
    )->run;
    
    $proxy->comm_handle($proc->delegate('comm')->handle);
    
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
    
    # handle status updates from tunnel creation
    $proc->delegate('stdout')->handle->on_read(sub {
        my ($hdl) = @_;
        $hdl->push_read(line => sub {
            my (undef, $line) = @_;
            
            $status_callback->("$line");
            if ($line && uc $line eq 'OK') {
                # tunnel now active...

                $started = 1;
                $tunnel = new IRC::RemoteControl::Proxy::Tunnel(
                    subprocess => $proc,
                    proxy => $proxy,
                    type => $proxy->type,
                );
                
                $self->tunnels->{$tunnel->id} = $tunnel;
            } elsif ($line && uc $line eq 'FAILED') {
                $started = 0;
            } else {
                $line ||= 'undef';
                $status_callback->("got unknown status: $line");
            }
        });
    });
    
    push @{$self->subprocs}, $proc;
}

# get all active tunnels, optionally filtered by $type
sub all_tunnels {
    my ($self, $type) = @_;
    
    my @tunnels = values %{$self->tunnels};
    @tunnels = grep { $_->type eq $type } @tunnels if $type;
    
    return @tunnels;
}

__PACKAGE__->meta->make_immutable;
