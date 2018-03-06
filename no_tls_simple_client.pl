use strict;
use warnings;
use feature 'say';
use AnyEvent;
use AnyEvent::Socket;
use AnyEvent::Handle;

use Protocol::HTTP2::Client;
use Protocol::HTTP2::Constants qw(const_name);

use JSON;
use Term::ANSIColor;
my $json = JSON->new->utf8->pretty->canonical;
sub _dump {
    say $json->encode(@_);
}

my $port = 8080;
my $host = '127.0.0.1';

my $client = Protocol::HTTP2::Client->new(
    on_change_state => sub {
        my ($stream_id, $previous_state, $current_state) = @_;
        say colored ['yellow'] => sprintf(
            '> Stream %i changed state from %s to %s',
            $stream_id,
            const_name(states => $previous_state),
            const_name(states => $current_state),
        );
    },
    on_error => sub {
        my $error = shift;
        say colored ['red'] => sprintf(
            'Error occurred: %s',
            const_name(errors => $error),
        );
    },
);

# Prepare request
$client->request(
    # HTTP/2 headers
    ':scheme'    => 'http',
    ':authority' => "$host:$port",
    ':path'      => '/',
    ':method'    => 'GET',

    # HTTP/1.1 headers
    headers => [
        'accept'     => '*/*',
        'user-agent' => "perl-Protocol-HTTP2/$Protocol::HTTP2::VERSION",
    ],

    on_done => sub {
        my ($headers, $data) = @_;
        _dump [ $headers, $data ];
    },
);

my $w = AnyEvent->condvar;

tcp_connect $host, $port, sub {
    my ($fh) = @_ or die "connection failed: $!";

    my $handle;
    $handle = AnyEvent::Handle->new(
        fh       => $fh,
        autocork => 1,
        on_error => sub {
            $_[0]->destroy;
            print "connection error\n";
            $w->send;
        },
        on_eof => sub {
            $handle->destroy;
            $w->send;
        },
    );

    # First write preface to peer
    while (my $frame = $client->next_frame) {
        $handle->push_write($frame);
    }

    $handle->on_read(sub {
        my $handle = shift;
        $client->feed($handle->{rbuf});
        $handle->{rbuf} = undef;

        while (my $frame = $client->next_frame) {
            $handle->push_write($frame);
        }
        $handle->push_shutdown if $client->shutdown;
    });
};

$w->recv;
