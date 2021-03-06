package TestAPIcastBlackbox;
use strict;
use warnings FATAL => 'all';
use v5.10.1;
use JSON;

use lib 't';
use TestAPIcast  -Base;
use File::Copy "move";
use File::Temp qw/ tempfile /;

BEGIN {
    $ENV{APICAST_OPENRESTY_BINARY} = $ENV{TEST_NGINX_BINARY};
}

add_block_preprocessor(sub {
    my $block = shift;
    my $seq = $block->seq_num;
    my $name = $block->name;
    my $configuration = $block->configuration;
    my $backend = $block->backend;
    my $upstream = $block->upstream;
    my $sites_d = $block->sites_d || '';
    my $ServerPort = $Test::Nginx::Util::ServerPort;

    if (defined $backend) {
        $sites_d .= <<_EOC_;
        server {
            listen $ServerPort;

            server_name test_backend backend;

            $backend
        }

        upstream test_backend {
            server 127.0.0.1:$ServerPort;
        }

_EOC_
        $ENV{BACKEND_ENDPOINT_OVERRIDE} = "http://test_backend:$ServerPort";
    }

    if (defined $upstream) {
        $sites_d .= <<_EOC_;
        server {
            listen $ServerPort;

            server_name test;

            $upstream
        }

        upstream test {
            server 127.0.0.1:$ServerPort;
        }
_EOC_
    }

    if (defined $configuration) {
        $configuration = Test::Nginx::Util::expand_env_in_config($configuration);
        decode_json($configuration);
        $block->set_value("configuration", $configuration);
    }

    $block->set_value("config", "$name ($seq)");
    $block->set_value('sites_d', $sites_d)
});

my $write_nginx_config = sub {
    my $block = shift;

    my $ConfFile = $Test::Nginx::Util::ConfFile;
    my $Workers = $Test::Nginx::Util::Workers;
    my $MasterProcessEnabled = $Test::Nginx::Util::MasterProcessEnabled;
    my $DaemonEnabled = $Test::Nginx::Util::DaemonEnabled;
    my $err_log_file = $block->error_log_file || $Test::Nginx::Util::ErrLogFile;
    my $LogLevel = $Test::Nginx::Util::LogLevel;
    my $PidFile = $Test::Nginx::Util::PidFile;
    my $AccLogFile = $Test::Nginx::Util::AccLogFile;
    my $ServerPort = $Test::Nginx::Util::ServerPort;

    my $sites_d = $block->sites_d;


    my $configuration = $block->configuration;
    my $conf;
    my $configuration_file = $block->configuration_file;

    if (defined $configuration_file) {
        chomp($configuration_file);
        $configuration_file = "$configuration_file";
    } else {
        if (defined $configuration) {
            ($conf, $configuration_file) = tempfile();
            print $conf $configuration;
            close $conf;

            $configuration_file = "$configuration_file";
        }
    }

    my ($env, $env_file) = tempfile();
    print $env <<_EOC_;
return {
    worker_processes = '$Workers',
    master_process = '$MasterProcessEnabled',
    daemon = '$DaemonEnabled',
    error_log = '$err_log_file',
    log_level = '$LogLevel',
    pid = '$PidFile',
    lua_code_cache = 'on',
    access_log = '$AccLogFile',
    port = { apicast = '$ServerPort' },
    env = {
        THREESCALE_CONFIG_FILE = [[$configuration_file]],
        APICAST_CONFIGURATION_LOADER = 'boot',
    },
    sites_d = [============================[$sites_d]============================],
}
_EOC_
    close $env;

    my $apicast = `APICAST_CONFIGURATION_LOADER="" bin/apicast start --test --environment $env_file --configuration $configuration_file 2>&1`;
    if ($apicast =~ /configuration file (?<file>.+?) test is successful/)
    {
        move($+{file}, $ConfFile);
    } else {
        warn "Missing config file: $Test::Nginx::Util::ConfFile";
        warn $apicast;
    }

    if ($PidFile && -f $PidFile) {
        unlink $PidFile or warn "Couldn't remove $PidFile.\n";
    }

    $ENV{APICAST_LOADED_ENVIRONMENTS} = $env_file;
};

BEGIN {
    no warnings 'redefine';

    sub Test::Nginx::Util::write_config_file ($$) {
        my $block = shift;
        return $write_nginx_config->($block);
    }
}

1;
