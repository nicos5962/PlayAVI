package Plugins::PlayAVI::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::Base);

use Slim::Utils::Log;
use Plugins::PlayAVI::Register;

my $log = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.playavi',
    defaultLevel => 'INFO',
    description  => 'PLUGIN_PLAYAVI',
});

sub initPlugin {
    my $class = shift;

    my $version = $class->_pluginDataFor('version') || 'unknown';
    $log->info("Initializing PlayAVI plugin $version");

    Plugins::PlayAVI::Register->registerFormatHandler();

    $class->SUPER::initPlugin(@_);
}

sub getDisplayName { 'PLUGIN_PLAYAVI' }

1;
