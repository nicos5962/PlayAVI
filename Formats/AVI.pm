package Plugins::PlayAVI::Formats::AVI;

# Video containers (AVI, MKV, MPG, ...) are not supported by Audio::Scan. The
# audio properties and the tags are read with ffprobe. The file is handled as
# audio: only its first audio stream is used, the video is ignored.
# What the file does not contain is guessed from its name and its folder.
# An external album id is set from the Discogs release id so that different
# releases of the same album / artist are not merged into one album.
#
# The plugins for the other video containers are built on this class. They
# override types, logCategory and pluginName, and where needed _contentType
# and _wantsFile. A plugin of its own needs a custom-types.conf entry, a
# custom-convert.conf and a Register.pm registering its types.

use strict;
use warnings;
use base qw(Slim::Formats);

use Digest::MD5 qw(md5_hex);
use Encode ();
use File::Basename qw(fileparse);
use File::Spec;
use JSON::XS qw(decode_json);

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;

my $prefs = preferences('server');
my %logs;

# Server types handled by the plugin (see custom-types.conf). Each one is
# registered as a tag reader. The first one is the content type of the files
# the plugin reads.
sub types       { qw(avi) }
sub logCategory { 'plugin.playavi' }
sub pluginName  { 'PlayAVI' }

sub _log {
    my $class = shift;

    return $logs{$class} //= logger($class->logCategory);
}

# The content type of the files the plugin reads: its first type
sub _contentType { ($_[0]->types)[0] }

# Whether the plugin takes a file, given whether it holds a video stream
sub _wantsFile { 1 }

# ffprobe tag names (upper case) to the names used by the server. A mapping
# never overwrites a value that is already present.
my %tagMapping = (
    'TRACK'             => 'TRACKNUM',
    'DATE'              => 'YEAR',
    'ALBUM_ARTIST'      => 'ALBUMARTIST',
    'ALBUM ARTIST'      => 'ALBUMARTIST',
    'ALBUM_ARTIST_SORT' => 'ALBUMARTISTSORT',
    'ARTIST_SORT'       => 'ARTISTSORT',
    'ALBUM_SORT'        => 'ALBUMSORT',
    'TITLE_SORT'        => 'TITLESORT',
    'UNSYNCEDLYRICS'    => 'LYRICS',
    'RELEASEDATE'       => 'YEAR',
);

# Names under which taggers store the disc number, the number of discs and the
# disc title, in order of preference.
my @discNumberKeys = ('DISCNUMBER', 'DISC', 'DISC NUMBER', 'DISC_NUMBER');
my @discTotalKeys  = ('DISCTOTAL', 'TOTALDISCS', 'DISC_TOTAL', 'DISC TOTAL', 'DISCC');
my @discTitleKeys  = (
    'DISCSUBTITLE', 'DISC SUBTITLE', 'DISC_SUBTITLE',
    'DISCTITLE', 'DISC TITLE', 'DISC_TITLE', 'SETSUBTITLE', 'SET SUBTITLE',
);

# Normalized names (upper case, letters and digits only) of the tags holding
# the Discogs release id, in order of preference.
my @extIdNames = qw(DISCOGSRELEASEID DISCOGSID DISCOGSRELEASE);

# Audio codecs without loss
my $losslessCodec = qr/^(?:pcm_|flac$|alac$|ape$|tta$|wavpack$|truehd$|mlp$|shorten$|tak$)/;

# ---------------------------------------------------------------------------
# Guessing tags from the path. Used for what the file does not contain.
# ---------------------------------------------------------------------------

# Recording names, tried first, in order, first match wins. Named captures:
# show, season, ep, title, d/m/y/hh/mm (recording date and time).
my @tvPatterns = (
    # "Show - S2015e01 - Title[ - 14-01-2016 20h48[ 02h05][ (13)]]"
    # The recording date and time are optional.
    {
        name => 'tv-recording',
        re   => qr/^(?<show>.+?)\s+-\s+S(?<season>\d{2,4})E(?<ep>\d+)\s+-\s+(?<title>.+?)
                   (?:\s+-\s+(?<d>\d{2})-(?<m>\d{2})-(?<y>\d{4})\s+(?<hh>\d{2})h(?<mm>\d{2})
                      (?:\s+\d{1,2}h\d{2}m?)?(?:\s+\(\d+\))?)?$/xi,
    },
    # "Channel - Title - 02-12-2016 20h49 01h07 (46)"  (no episode number)
    # The date is required, so that "Artist - Title" does not match.
    {
        name => 'tv-recording-dated',
        re   => qr/^(?<show>.+?)\s+-\s+(?<title>.+?)
                   \s+-\s+(?<d>\d{2})-(?<m>\d{2})-(?<y>\d{4})\s+(?<hh>\d{2})h(?<mm>\d{2})
                   (?:\s+\d{1,2}h\d{2}m?)?(?:\s+\(\d+\))?$/xi,
    },
);

# "1.01. Title", "2-03 Title": disc and track number
my $discTrackRe = qr/^(?<d>\d{1,2})[.-](?<t>\d{2,3})(?:\.\s+|\s+-\s+|_|\s+)(?<rest>\S.*)$/;

# "01 - Title", "01. Title", "01_Title", "02 Title": track number. A dot or
# dash must be followed by a space, so that "50.Cent - Title" is not a track
# number, and a space alone only counts after a leading zero ("2 Unlimited").
my $trackRe = qr/^(?<t>\d{1,3})(?:\s*[-.]\s+|_)(?<rest>\S.*)$|^(?<t>0\d)\s+(?<rest>\S.*)$/;

# "Artist - 1994-10-05 Title": concert date before the title
my $datedTitleRe = qr/^(?<artist>.+?)\s+-\s+(?<y>\d{4})-(?<m>\d{2})-(?<d>\d{2})\s+(?<title>.+)$/;

# "Artist - 01 - Title"
my $artistTrackTitleRe = qr/^(?<artist>.+?)\s+-\s+(?<t>\d{1,3})\s*[-.]\s+(?<title>\S.*)$/;

# "Artist - Title"
my $artistTitleRe = qr/^(?<artist>.+?)\s+-\s+(?<title>.+)$/;

# Parent folder of DVD / video rips: "(2003) Album [info] [rip id]", or with the
# concert date "(1995-10-15) Place". The artist is the folder above it.
my $ripFolderRe = qr/^\((?<year>\d{4})(?<date>-\d{2}(?:-\d{2})?)?\)\s+(?<album>.+?)(?:\s*\[(?<info>[^\]]*)\])?(?:\s*\[[^\]]*\])*\s*$/;

# Folder "Artist - Album [info]" or "Artist - 1994 - Album [info]"
my $artistAlbumFolderRe = qr/^(?<artist>.+?)\s+-\s+(?:(?<year>(?:19|20)\d{2})\s+-\s+)?(?<album>.+?)
                             (?:\s*\[(?<info>[^\]]*)\])?(?:\s*\[[^\]]*\])*\s*$/x;

# Folder holding one disc of an album: "CD1", "Disc 2", "DVD 1"
my $discFolderRe = qr/^(?:cd|disc|disk|dvd|dvdr?)\s*[-_.]?\s*(\d{1,2})$/i;

# Names given to audio streams that are no track title: "Stereo", "Surround 5.1", "Dolby Digital 5.1"
my $genericStreamTitle = qr/^(?:(?:stereo|mono|surround|audio|main|dolby|digital|ac-?3|e-?ac-?3|dts|dts-hd|aac|mp[23]|lpcm|pcm|truehd|ma|hd|\d(?:\.\d)?|ch|channels?|\d+\s*kbps)[\s_.-]*)+$/i;

# Folders that name no album
my %genericFolder = map { $_ => 1 }
    qw(video videos movie movies music concert concerts clip clips download downloads tv recordings);

sub _decode {
    my ($s) = @_;
    return $s if !defined $s || Encode::is_utf8($s);
    my $d = eval { Encode::decode('UTF-8', $s, Encode::FB_CROAK | Encode::LEAVE_SRC) };
    return defined $d ? $d : Encode::decode('iso-8859-1', $s);
}

# Returns a hash of the tags that can be guessed from the file name and folder.
# Tags found in the file always win, so the caller only uses what is missing.
#   ALBUM    <- folder name ("Artist - Album [info]", "(Year) Album [info]")
#   ARTIST   <- "Artist - " prefix of the name, or the folder; "Various" for TV
#   TRACKNUM <- "01 - ", "1.01. " prefix of the name, or the episode number
#   DISC     <- "CD1" folder, or "1.01." prefix of the name
#   ALBUM_EXTID <- "[r2502632]" in the folder name (Discogs release id)
#   YEAR     <- folder, concert date, or season of a recording
#   COMMENT  <- information in brackets, or the recording date and time
sub _guessTags {
    my ($class, $file) = @_;

    my $log = $class->_log;
    my $pn  = $class->pluginName;

    my ($base, $dir) = fileparse($file, qr/\.[^.\/]+$/);
    $base = _decode($base);
    $base =~ s/\s+-\s+YouTube(?:\s*\[[^\]]*\])*\s*$//i;
    $base =~ s/^\s+|\s+$//g;

    my @raw  = grep { length } File::Spec->splitdir($dir);
    my @dirs = map { _decode($_) } @raw;

    my (%f, %b);

    # CD1 and the like: not the album, the album is one level up
    if (@dirs && $dirs[-1] =~ $discFolderRe) {
        $f{DISC} = $1 + 0;
        pop @dirs;
        pop @raw;
    }

    # a file in the media folder itself has no folder to guess from
    @dirs = () if @raw && _isMediaDir(File::Spec->catdir(File::Spec->rootdir, @raw));

    my $folder = @dirs ? $dirs[-1] : undef;

    # "[r2502632]": the Discogs release id, as written by the ripping tools.
    # It names no album, so it is taken out of the folder name.
    if (defined $folder) {
        my @ids;

        push @ids, $1 while $folder =~ s/\s*\[\s*r(\d+)\s*\]//i;

        $f{ALBUM_EXTID} = $ids[0] if @ids;

        $folder =~ s/^\s+|\s+$//g;
    }

    undef $folder if defined $folder && (!length $folder || $genericFolder{ lc $folder });

    my $rip;

    if (defined $folder) {
        if (@dirs > 1 && $folder =~ $ripFolderRe) {
            my %c = %+;
            $rip = 1;
            @f{qw(ARTIST ALBUMARTIST)} = ($dirs[-2]) x 2;
            $f{ALBUM}   = $c{album};
            $f{YEAR}    = $c{year};
            $f{COMMENT} = $c{info} if defined $c{info} && length $c{info};
            $f{COMMENT} //= "$c{year}$c{date}" if defined $c{date};
        }
        elsif ($folder =~ $artistAlbumFolderRe) {
            my %c = %+;
            @f{qw(ARTIST ALBUMARTIST)} = ($c{artist}) x 2;
            $f{ALBUM}   = $c{album};
            $f{YEAR}    = $c{year} if defined $c{year};
            $f{COMMENT} = $c{info} if defined $c{info} && length $c{info};
        }
        else {
            $f{ALBUM} = $folder;
        }
    }

    # recordings: the name has its own layout
    for my $p (@tvPatterns) {
        next unless $base =~ $p->{re};
        my %c = %+;

        main::DEBUGLOG && $log->is_debug && $log->debug("$pn: '$base' matched pattern $p->{name}");

        $b{ARTIST}      = 'Various';
        $b{COMPILATION} = 1;
        $b{TITLE}       = $c{title};
        $b{TRACKNUM}    = $c{ep} + 0 if defined $c{ep};
        $b{YEAR}        = $c{season} if defined $c{season} && $c{season} =~ /^(?:19|20)\d{2}$/;
        $b{COMMENT}     = "Recorded $c{y}-$c{m}-$c{d} $c{hh}:$c{mm}" if defined $c{y};

        return _finish(\%f, \%b);
    }

    # track number (and disc number) in front of the name
    if ($base =~ $discTrackRe) {
        my %c = %+;
        ($b{DISC}, $b{TRACKNUM}, $base) = ($c{d} + 0, $c{t} + 0, $c{rest});
    }
    elsif ($base =~ $trackRe) {
        my %c = %+;
        ($b{TRACKNUM}, $base) = ($c{t} + 0, $c{rest});
    }

    $base =~ s/^\s+|\s+$//g;

    # rip layout: the folder gives artist and album, the name is the title
    if ($rip) {
        $b{TITLE} = $base if length $base;
        return _finish(\%f, \%b);
    }

    # "AnthraxWacken20132" in folder "Wacken 2013": <Artist><Folder squeezed><n>
    # The folder name (words glued, optional separators) is located in the name;
    # what precedes it is the artist, trailing digits a part number. An artist
    # holding " - " is a "Artist - Title" name that only ends with the folder.
    if (defined $folder && $folder =~ /\w/) {
        my $folderRe = _squeezed($folder);

        if (length $folderRe
            && $base =~ /^(?<artist>.*?\S)[\s_.-]*$folderRe[\s_.-]*(?<n>\d{1,2})?$/i
            && $+{artist} !~ /\s-\s/)
        {
            my %c = %+;
            my $artist = $c{artist};
            $artist =~ s/_/ /g;
            # "IronMaiden" -> "Iron Maiden"
            $artist =~ s/(?<=[[:lower:]])(?=[[:upper:]])/ /g;

            main::DEBUGLOG && $log->is_debug && $log->debug("$pn: '$base' matched <artist><folder><n>");

            $b{ARTIST}   = $artist;
            $b{TITLE}    = "$artist - $folder";
            $b{TRACKNUM} = $c{n} + 0 if defined $c{n} && !defined $b{TRACKNUM};

            return _finish(\%f, \%b);
        }
    }

    if ($base =~ $datedTitleRe) {
        my %c = %+;
        @b{qw(ARTIST TITLE YEAR)} = ($c{artist}, $c{title}, $c{y});
        $b{COMMENT} = "$c{y}-$c{m}-$c{d}";
        return _finish(\%f, \%b);
    }

    if ($base =~ $artistTrackTitleRe) {
        my %c = %+;
        @b{qw(ARTIST TITLE)} = ($c{artist}, $c{title});
        $b{TRACKNUM} //= $c{t} + 0;
        return _finish(\%f, \%b);
    }

    if ($base =~ $artistTitleRe) {
        my %c = %+;
        @b{qw(ARTIST TITLE)} = ($c{artist}, $c{title});
        return _finish(\%f, \%b);
    }

    # "Sonic Youth 1998 raw" in folder "Sonic Youth": the name starts with the
    # folder, which is then the artist. Skipped for folders containing a year
    # ("Wacken 2013" is an event, not an artist).
    if (defined $folder && $folder !~ /\d{4}/ && !defined $f{ARTIST}) {
        my $folderRe = _squeezed($folder);

        if (length $folderRe && $base =~ /^$folderRe[\s_.-]+(?<rest>.+)$/i) {
            my $rest = $+{rest};
            my $year;
            $year = $1 if $rest =~ s/^((?:19|20)\d{2})(?:[\s_.-]+|$)//;

            main::DEBUGLOG && $log->is_debug && $log->debug("$pn: '$base' starts with folder name");

            $b{ARTIST} = $folder;
            $b{YEAR}   = $year if defined $year;
            $b{TITLE}  = length $rest ? $rest : $base;

            return _finish(\%f, \%b);
        }
    }

    $b{TITLE} = $base if length $base;

    return _finish(\%f, \%b);
}

# "Wacken 2013" -> a pattern matching "Wacken2013", "Wacken_2013", ...
sub _squeezed {
    my ($folder) = @_;

    return join '[\s_.-]*', map { quotemeta } grep { length } split /[\s_.-]+/, $folder;
}

sub _isMediaDir {
    my ($path) = @_;

    my $dirs = eval { Slim::Utils::Misc::getAudioDirs() };

    return 0 unless ref $dirs eq 'ARRAY';

    for my $dir (@$dirs) {
        next unless defined $dir && length $dir;

        (my $d = $dir) =~ s{/+$}{};

        return 1 if $d eq $path;
    }

    return 0;
}

# Folder values are the defaults, those of the name win. Names and titles
# get the case fixed, as guessed words often come in odd shapes.
sub _finish {
    my ($f, $b) = @_;

    my %g = (%$f, %$b);

    for my $key (qw(ARTIST ALBUM ALBUMARTIST TITLE)) {
        $g{$key} = _tidy($g{$key}) if defined $g{$key};
    }

    return \%g;
}

# Words glued with "_" get spaces. Shouting or all lower case values of several
# words get a capital for each word. Mixed case values are left alone, and so
# are single words, which are often acronyms or a chosen style (ABBA, KISS,
# deadmau5).
sub _tidy {
    my ($s) = @_;

    $s =~ s/^\s+|\s+$//g;
    $s =~ s/_/ /g if $s !~ /\s/;

    return $s unless $s =~ /\p{L}/ && $s =~ /\s/;

    my $upper = $s !~ /\p{Ll}/;
    my $lower = $s !~ /\p{Lu}/;

    return $s unless $upper || $lower;

    my $first = 1;

    $s =~ s{(?<![\p{L}\p{N}'\x{2019}])(\p{L}[\p{L}\p{N}'\x{2019}]*)}{
        my ($word, $lc) = ($1, lc $1);
        my $out;

        if    ($upper && $word =~ /^(?:II|III|IV|VI|VII|VIII|IX|XI|XII)$/) { $out = $word }
        elsif (!$first && $lc =~ /^(?:a|an|and|as|at|but|by|for|in|of|on|or|the|to|vs|via)$/) { $out = $lc }
        else  { $out = ucfirst $lc }

        $first = 0;
        $out;
    }ge;

    return $s;
}

sub getTag {
    my ($class, $file, $anchor) = @_;
    return {} unless $file;

    my $log = $class->_log;
    my $pn  = $class->pluginName;

    my $probe = $class->_probe($file) or return;

    my $format  = $probe->{format} || {};
    my @streams = @{ $probe->{streams} || [] };
    my ($stream) = grep { ($_->{codec_type} // '') eq 'audio' } @streams;

    unless ($stream && $stream->{sample_rate}) {
        main::DEBUGLOG && $log->is_debug && $log->debug("$pn: no audio stream in $file");
        return;
    }

    # a picture in the file is cover art, a video without one gets a frame
    my ($hasVideo, $hasCover);

    for my $s (grep { ($_->{codec_type} // '') eq 'video' } @streams) {
        if ($s->{disposition} && $s->{disposition}->{attached_pic}) { $hasCover = 1 }
        else                                                         { $hasVideo = 1 }
    }

    return unless $class->_wantsFile($hasVideo);

    my $secs = $format->{duration} || $stream->{duration};

    unless ($secs && $secs > 0) {
        $log->warn("$pn: no duration found for $file");
        return;
    }

    my $tags = {};

    # tags of the container, then those of the audio stream for what is missing
    for my $source ($format->{tags}, $stream->{tags}) {
        next unless ref $source eq 'HASH';

        for my $key (keys %$source) {
            my $value = $source->{$key};
            next unless defined $value && !ref $value && length $value;

            # the title of an audio stream is often only its name ("Stereo"): not a track title
            next if uc $key eq 'TITLE' && $source == $stream->{tags} && $value =~ $genericStreamTitle;

            $tags->{ uc $key } //= $value;
        }
    }

    # the server only calls getCoverArt for tracks with a cover length
    $tags->{COVER_LENGTH} = 1 if $hasCover;

    # properties of the first audio stream
    my $codec    = $stream->{codec_name} // '';
    my $lossless = $codec =~ $losslessCodec ? 1 : 0;

    $tags->{SIZE}         = -s $file;
    $tags->{OFFSET}       = 0;
    $tags->{SECS}         = $secs + 0;
    $tags->{RATE}         = $stream->{sample_rate} + 0;
    $tags->{LOSSLESS}     = $lossless;
    $tags->{CONTENT_TYPE} = $class->_contentType($file);

    # the transcoding rules output 16 bit stereo (-ac 2, pcm_s16le): the tags
    # describe what the players get, as raw PCM carries no header of its own
    $tags->{CHANNELS}   = 2;
    $tags->{SAMPLESIZE} = 16;

    # the bitrate of the container includes the video: use the audio one only
    if ($stream->{bit_rate}) {
        $tags->{BITRATE} = int $stream->{bit_rate};
    }
    elsif ($codec =~ /^pcm_/ && $stream->{channels}) {
        $tags->{BITRATE} = $tags->{RATE} * $stream->{channels} * ($stream->{bits_per_sample} || 16);
    }

    $class->_mapDisc($tags);
    $class->_mapTags($tags);

    # the Discogs id of the file comes before the one of the folder name
    $class->_setExtId($tags);

    # what the file does not contain comes from its name and folder
    my $guessed   = $class->_guessTags($file);
    my $hadArtist = defined $tags->{ARTIST};

    for my $key (keys %$guessed) {
        # an artist in the file is not an album artist guessed from a folder
        next if $key eq 'ALBUMARTIST' && $hadArtist;

        $tags->{$key} //= $guessed->{$key};
    }

    if ($hasVideo && !$tags->{COVER_LENGTH} && !$tags->{COVER}) {
        my $cover = $class->_videoFrameCover($file, $secs);

        $tags->{COVER} = $cover if $cover;
    }

    main::DEBUGLOG && $log->is_debug && $log->debug(sprintf(
        "$pn: %s - %s %s Hz / %s ch / %s sec -> artist='%s' title='%s' album='%s'",
        $file, $codec, $tags->{RATE}, $stream->{channels} // '?', $tags->{SECS},
        map { $_ // '' } @$tags{qw(ARTIST TITLE ALBUM)},
    ));

    return $tags;
}

# Cover art: the picture attached to the file. Folder art (cover.jpg and the
# like) is found by the server itself.
sub getCoverArt {
    my ($class, $file) = @_;
    return unless $file;

    return $class->_capture(15, 'ffmpeg', qw(-nostdin -v quiet -i), $file,
        qw(-map 0:v:0 -frames:v 1 -f image2pipe -c:v mjpeg -));
}

sub canSeek { 1 }

# ---------------------------------------------------------------------------
# Tools. Run without a shell, so file names need no quoting.
# ---------------------------------------------------------------------------

# Output of the tool, or undef when it ran badly or printed nothing.
sub _capture {
    my ($class, $timeout, $tool, @args) = @_;

    my @cmd = (Slim::Utils::Misc::findbin($tool) || $tool, @args);

    unshift @cmd, '/usr/bin/timeout', $timeout if -x '/usr/bin/timeout';

    open my $ph, '-|', @cmd or do {
        $class->_log->warn($class->pluginName . ": could not run $tool: $!");
        return;
    };

    binmode $ph;

    my $data = do { local $/; <$ph> };

    close $ph;

    return (defined $data && length $data) ? $data : undef;
}

sub _probe {
    my ($class, $file) = @_;

    my $log = $class->_log;
    my $pn  = $class->pluginName;

    my $json = $class->_capture(30, 'ffprobe', qw(-v quiet -print_format json -show_format -show_streams), '-i', $file);

    unless (defined $json) {
        $log->warn("$pn: ffprobe returned nothing for $file");
        return;
    }

    my $probe = eval { decode_json($json) };

    unless (ref $probe eq 'HASH') {
        $log->warn("$pn: failed to decode ffprobe output for $file: " . ($@ || 'unexpected data'));
        return;
    }

    return $probe;
}

# ---------------------------------------------------------------------------
# Video frame cover. Returns the path of a cached JPEG (rendered on first use)
# or undef when the folder already holds an image, or no frame could be made.
# The server stores that path as the track's cover, as for a cover.jpg in the
# folder. The cache files must stay in place.
# ---------------------------------------------------------------------------
my @folderArt = qw(cover folder album front thumb albumart);
my @artExt    = qw(jpg jpeg png gif);

sub _videoFrameCover {
    my ($class, $file, $secs) = @_;

    return if _hasFolderArt($file);

    my @st = stat($file) or return;

    my $dir = File::Spec->catdir($prefs->get('cachedir') || File::Spec->tmpdir, lc $class->pluginName);

    mkdir $dir unless -d $dir;

    return unless -d $dir && -w $dir;

    my $cache = File::Spec->catfile($dir, md5_hex(join '|', $file, $st[7], $st[9]) . '.jpg');

    return $cache if -s $cache;

    # about 20% into the clip skips intros and black frames; at most 5 minutes
    my $seek = $secs ? sprintf('%.1f', $secs * 0.20 > 300 ? 300 : $secs * 0.20) : 10;

    my $data = $class->_renderFrame($file, $seek);

    # short or odd clips: retry from the start
    $data = $class->_renderFrame($file, 0) if !defined $data && $seek ne '0';

    return unless defined $data;

    open my $fh, '>:raw', $cache or do {
        $class->_log->warn($class->pluginName . ": cannot write $cache: $!");
        return;
    };

    print $fh $data;
    close $fh;

    return $cache;
}

sub _renderFrame {
    my ($class, $file, $seek) = @_;

    return $class->_capture(30, 'ffmpeg', qw(-nostdin -v quiet -ss), $seek, '-i', $file,
        qw(-map 0:v:0 -an -frames:v 1),
        '-vf', q{thumbnail=30,scale='min(600,iw)':-2},
        qw(-f image2pipe -c:v mjpeg -));
}

# True when the folder contains cover.jpg, folder.png, <name>.jpg ... etc.
sub _hasFolderArt {
    my ($file) = @_;

    my ($base, $dir) = fileparse($file, qr/\.[^.\/]+$/);

    opendir my $dh, $dir or return 0;

    my %wanted = map { lc($_) => 1 } (@folderArt, $base);
    my $found  = 0;

    for my $f (readdir $dh) {
        next unless $f =~ /^(.+)\.([^.]+)$/;

        my ($name, $ext) = (lc $1, lc $2);

        if ($wanted{$name} && grep { $_ eq $ext } @artExt) {
            $found = 1;
            last;
        }
    }

    closedir $dh;

    return $found;
}

# ---------------------------------------------------------------------------
# Tag mapping
# ---------------------------------------------------------------------------
sub _mapTags {
    my ($class, $tags) = @_;

    while (my ($old, $new) = each %tagMapping) {
        next unless exists $tags->{$old};

        my $value = delete $tags->{$old};
        $tags->{$new} = $value unless defined $tags->{$new};
    }

    # TRACK=3/12
    if (defined $tags->{TRACKNUM} && $tags->{TRACKNUM} =~ m{^\s*(\d+)}) {
        $tags->{TRACKNUM} = $1 + 0;
    }

    # DATE=2007-08-04: the server only accepts a year
    if (defined $tags->{YEAR}) {
        if ($tags->{YEAR} =~ /(\d{4})/) {
            $tags->{YEAR} = $1;
        }
        else {
            delete $tags->{YEAR};
        }
    }
}

# Sets DISC, DISCC and DISCSUBTITLE the way the server expects them: plain
# numbers (core drops anything else, and disc 0), first value only.
sub _mapDisc {
    my ($class, $tags) = @_;

    my $disc  = _takeFirst($tags, @discNumberKeys);
    my $discc = _takeFirst($tags, @discTotalKeys);
    my $title = _takeFirst($tags, @discTitleKeys);

    if (defined $disc) {
        # 1/2, 1-2, 1 of 2: a number of discs in its own tag wins
        if ($disc =~ m{(\d+)\s*(?:/|-|of)\s*(\d+)}i) {
            ($disc, $discc) = ($1, $discc // $2);
        }
        # Disc 2, 02
        elsif ($disc =~ /(\d+)/) {
            $disc = $1;
        }
        else {
            undef $disc;
        }
    }

    $discc = $1 if defined $discc && $discc =~ /(\d+)/;

    $tags->{DISC}         = $disc + 0  if $disc;
    $tags->{DISCC}        = $discc + 0 if $discc;
    $tags->{DISCSUBTITLE} = $title     if defined $title;
}

# Removes the tags and returns the first value that is not empty.
sub _takeFirst {
    my ($tags, @keys) = @_;

    my $found;

    for my $key (@keys) {
        next unless exists $tags->{$key};

        my $values = delete $tags->{$key};

        for my $value (ref $values eq 'ARRAY' ? @$values : $values) {
            next if !defined $value || ref $value;

            (my $trimmed = $value) =~ s/^\s+|\s+$//g;

            $found //= $trimmed if length $trimmed;
        }
    }

    return $found;
}

sub _setExtId {
    my ($class, $tags) = @_;

    return if $tags->{ALBUM_EXTID};

    my %byName;

    for my $key (keys %$tags) {
        (my $name = uc $key) =~ s/[^A-Z0-9]//g;

        $byName{$name} //= $tags->{$key};
    }

    for my $name (@extIdNames) {
        my $value = $byName{$name};
        $value = $value->[0] if ref $value eq 'ARRAY';

        next if !defined $value || ref $value;

        $value =~ s/^\s+|\s+$//g;

        if (length $value) {
            $tags->{ALBUM_EXTID} = $value;
            return;
        }
    }
}

1;
