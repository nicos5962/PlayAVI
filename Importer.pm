package Plugins::PlayAVI::Importer;

use strict;
use warnings;

use Plugins::PlayAVI::Register;

sub initPlugin {
    my $class = shift;

    Plugins::PlayAVI::Register->registerFormatHandler();
    return 1;
}

sub startScan {
    my $class = shift;
    return;
}

1;
