#!/usr/bin/env perl

use strict;
use warnings;

use lib 'lib';
use IRC::RemoteControl;
use AnyEvent;
use AnyEvent::Socket;

my $cv = AnyEvent->condvar;

my $target = shift @ARGV
    or die "Usage: $0 http://webchat.com/endpoint\n";

my $rc = IRC::RemoteControl->new_with_options(
    require_proxy => 1,
    debug => 0,
    target_address => $target,
    personalities => [qw/Webchat/],
    proxy_types => [qw/HTTP HTTPS/],
);

$SIG{INT} = sub {
    warn "Shutting down...\n";
    undef $rc;
    $cv->send;
};

$rc->start;

$cv->recv; # main loop
