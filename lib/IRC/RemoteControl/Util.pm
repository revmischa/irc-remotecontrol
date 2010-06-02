package IRC::RemoteControl::Util;

use strict;
use warnings;

use List::Util qw/shuffle/;

*gen_user = \&gen_nick;
*gen_real = \&gen_nick;

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

    my @wordlist = (shuffle @words)[0..int(rand(2) + 5)];

    my $nick = '';

    foreach my $word (@wordlist) {
        $word = ucfirst $word if int(rand(10)) < 5;
        $nick .= '_' if $nick && int(rand(10)) < 2;
        $nick .= $word;
    }

    $nick = substr($nick, 0, 8); # symbols max

    return $nick;
}


1;
