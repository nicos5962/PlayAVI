package Plugins::PlayAVI::Register;

# Registers the PlayAVI tag handler. Kept free of any web/UI dependency so it
# can be used by both the server plugin and the scanner importer.

use strict;
use warnings;

use Slim::Formats;
use Slim::Utils::Log;

use constant HANDLER => 'Plugins::PlayAVI::Formats::AVI';

my $log = logger('plugin.playavi');

sub registerFormatHandler {
    my ($class, $tagClasses) = @_;

    Slim::Formats->init();

    $tagClasses ||= \%Slim::Formats::tagClasses;

    return 0 unless ref($tagClasses) eq 'HASH';

    return 1 if defined $tagClasses->{avi} && $tagClasses->{avi} eq HANDLER;

    $tagClasses->{avi} = HANDLER;

    main::DEBUGLOG && $log->is_debug && $log->debug('PlayAVI: registered avi tag handler');

    return 1;
}

1;
