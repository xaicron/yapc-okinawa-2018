use strict;
use warnings;
use feature 'say';
use AnyEvent;
use AnyEvent::Socket;
use AnyEvent::Handle;

use Protocol::HTTP2::Server;
use Protocol::HTTP2::Constants qw(const_name);

use JSON;
use Term::ANSIColor;
my $json = JSON->new->utf8->pretty->canonical;
sub _dump {
    say $json->encode(@_);
}

my $port = 8080;
my $host = '127.0.0.1';

my $w = AnyEvent->condvar;

tcp_server $host, $port, sub {
    my ($fh, $peer_host, $peer_port) = @_;

    my $handle;
    $handle = AnyEvent::Handle->new(
        fh       => $fh,
        autocork => 1,
        on_error => sub {
            my ($handle, $fatal, $message) = @_;
            $handle->destroy;
            say colored ['red'] => sprintf(
                'connection error (fatal: %s, message: %s)',
                $fatal, $message,
            );
        },
        on_eof => sub {
            $handle->destroy;
        },
    );

    my $server;
    $server = Protocol::HTTP2::Server->new(
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
        on_request => sub {
            my ($stream_id, $headers, $req_data) = @_;
            say "on_request: stream_id: $stream_id";
            _dump [ $headers, $req_data];

            my $data = "Hello, HTTP/2!";
            $server->response(
                ':status' => 200,
                stream_id => $stream_id,
                headers   => [
                    'server'         => 'perl-Protocol-HTTP2/1.08',
                    'content-length' => length($data),
                ],
                data => $data,
            );
        },
    );

    while (my $frame = $server->next_frame) {
        $handle->push_write($frame);
    }

    $handle->on_read(sub {
        my $handle = shift;
        $server->feed($handle->{rbuf});
        $handle->{rbuf} = undef;
        while (my $frame = $server->next_frame) {
            $handle->push_write($frame);
        }
        $handle->push_shutdown if $server->shutdown;
    });
}, sub {
    my ($fh, $host, $port) = @_;
    say colored ['green'] => "Accepting connections at http://$host:$port/";
};

$w->recv;
