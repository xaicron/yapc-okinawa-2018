#!/usr/bin/env perl

use strict;
use warnings;
use feature 'say';
use AnyEvent;
use AnyEvent::Socket;
use AnyEvent::Handle;
use AnyEvent::TLS;
use AnyEvent::IO;

use Protocol::HTTP2::Server;
use Protocol::HTTP2::Constants qw(const_name);

use JSON;
use Term::ANSIColor;
my $json = JSON->new->utf8->pretty->canonical;
sub _dump {
    say $json->encode(@_);
}

Net::SSLeay::initialize();

my $port = 443;
my $host = 'http2-test.api.moe';

my $w = AnyEvent->condvar;

tcp_server undef, $port, sub {
    my ($fh, $peer_host, $peer_port) = @_;

    my $tls;
    eval {
        $tls = AnyEvent::TLS->new(
            method    => 'TLSv1_2',
            cert_file => '/etc/letsencrypt/live/http2-test.api.moe/fullchain.pem',
            key_file  => '/etc/letsencrypt/live/http2-test.api.moe/privkey.pem',
        );

        # ECDH curve ( Net-SSLeay >= 1.56, openssl >= 1.0.0 )
        if (exists &Net::SSLeay::CTX_set_tmp_ecdh) {
            my $curve = Net::SSLeay::OBJ_txt2nid('prime256v1');
            my $ecdh  = Net::SSLeay::EC_KEY_new_by_curve_name($curve);
            Net::SSLeay::CTX_set_tmp_ecdh( $tls->ctx, $ecdh );
            Net::SSLeay::EC_KEY_free($ecdh);
        }

        # ALPN (Net-SSLeay > 1.55, openssl >= 1.0.2)
        if (exists &Net::SSLeay::CTX_set_alpn_select_cb) {
            Net::SSLeay::CTX_set_alpn_select_cb(
                $tls->ctx,
                [ Protocol::HTTP2::ident_tls ],
            );
        }

        # NPN  (Net-SSLeay > 1.45, openssl >= 1.0.1)
        elsif (exists &Net::SSLeay::CTX_set_next_protos_advertised_cb) {
            Net::SSLeay::CTX_set_next_protos_advertised_cb(
                $tls->ctx,
                [ Protocol::HTTP2::ident_tls ],
            );
        }
        else {
            die 'ALPN and NPN is not supported';
        }
    };
    if ($@) {
        warn "Some problem with SSL CTX: $@";
        $w->send;
        return;
    }

    my $handle;
    $handle = AnyEvent::Handle->new(
        fh       => $fh,
        tls      => 'accept',
        tls_ctx  => $tls,
        autocork => 1,
        on_error => sub {
            my ($handle, $fatal, $message) = @_;
            $handle->destroy;
            say "connection error (fatal: $fatal, message: $message)";
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
            _dump [ $headers, $req_data ];

            my $header_map = { @$headers };
            if ($header_map->{':path'} eq '/push.html') {
                $server->push(
                    ':authority' => $host . ':' . $port,
                    ':method'    => 'GET',
                    ':path'      => '/style.css',
                    ':scheme'    => 'https',
                    stream_id    => $stream_id,
                );

                aio_load './push.html', sub {
                    my ($data) = @_;
                    $server->response(
                        ':status' => 200,
                        stream_id => $stream_id,
                        headers   => [
                            'server'         => 'perl-Protocol-HTTP2/1.08',
                            'content-length' => length($data),
                            'content-type'   => 'text/html',
                        ],
                        data => $data,
                    );
                };
            }
            elsif ($header_map->{':path'} eq '/style.css') {
                aio_load './style.css', sub {
                    my ($data) = @_;
                    $server->response(
                        ':status' => 200,
                        stream_id => $stream_id,
                        headers   => [
                            'server'         => 'perl-Protocol-HTTP2/1.08',
                            'content-length' => length($data),
                            'content-type'   => 'text/css',
                        ],
                        data => $data,
                    );
                };
            }
            else {
                my $data = 'Hello, HTTP/2!';
                $server->response(
                    ':status' => 200,
                    stream_id => $stream_id,
                    headers   => [
                        'server'         => "perl-Protocol-HTTP2/$Protocol::HTTP2::VERSION",
                        'content-length' => length($data),
                    ],
                    data => $data,
                );
            }
        },
    );

    while (my $frame = $server->next_frame) {
        $handle->push_write($frame);
    }

    $handle->on_read(
        sub {
            my $handle = shift;
            $server->feed($handle->{rbuf});
            $handle->{rbuf} = undef;
            while (my $frame = $server->next_frame) {
                $handle->push_write($frame);
            }
            $handle->push_shutdown if $server->shutdown;
        }
    );
}, sub {
    my ($fh, $host, $port) = @_;
    say colored ['green'] => "Accepting connections at https://$host:$port/";
};

$w->recv;
