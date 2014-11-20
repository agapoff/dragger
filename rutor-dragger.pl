#!/usr/bin/perl
use warnings;
use strict;
binmode(STDOUT,':utf8');
use LWP::UserAgent;
use Cwd qw( realpath );

use Data::Dumper;

my $configFile = 'dragger.cfg';
my $listFile = 'rutor.list';

our %cfg;
our %list;

my $scriptDir = script_dir();
parse_config($scriptDir.'/'.$configFile, \%cfg);
parse_list($scriptDir.'/'.$listFile, \%list);

our $debug = $cfg{debug};
$cfg{rutor}->{domain} || die "No rutor domain configured!";
my $torrentDir = $cfg{'torrent-dir'}||$scriptDir;

foreach my $url (keys %list) {
    my $torrentFilesNum = torrent_files($url);
    if ($torrentFilesNum > $list{$url}->{files}) {
        print "Amount of files has changed\n" if ($debug);
        my $torrent = find_torrent($url);
        if ($torrent && drag_torrent($torrent,$torrentDir)) {
            print "Changing list file\n" if ($debug);
            update_list($scriptDir.'/'.$listFile,$url,$torrentFilesNum);
        }
    }
    else {
        print "Previous amount was ".$list{$url}->{files}.". So I'm just exiting\n" if ($debug);
    }
}

exit;

sub drag_torrent {
    my ($url,$dir) = @_;
    $url = 'http://'.$cfg{rutor}->{domain}.$url;
    return unless ($url && $dir);
    my $ua = LWP::UserAgent->new;
    $ua->agent($cfg{'user-agent'}) if ($cfg{'user-agent'});
    print "Send GET to $url\n" if ($debug);
    my $req = $ua->get($url);
    print "Got ".$req->{_rc}." ".$req->{_msg}."\n" if ($debug);
    my $contentDisposition = $req->{_headers}->{'content-disposition'};
    if ($contentDisposition =~ /filename="?(.+?)("|$)/) {
        my $path = $dir.'/'.$1;
        open(TRNT, '>'.$path) || die "Cannot crate file '$path'\n";
        print TRNT $req->decoded_content( charset => 'none' );
        close TRNT;
        print "Saved torrent as '$path'\n" if ($debug);
        return 1;
    }
    print "Cannot get content-disposition from headers\n" if ($debug);
    return;
}

sub find_torrent {
    my $url = shift;
    $url = 'http://'.$cfg{rutor}->{domain}.$url;
    my $torrent = parse_page(get_page($url));
    return $torrent; 
}

sub torrent_files {
    my $url = shift;
    my $filesUrl;
    print "Trying to get amount of files in torrent\n" if ($debug);
    if ($url =~ /^\D+(\d+)/) {
        $filesUrl = 'http://'.$cfg{rutor}->{domain}.'/descriptions/'.$1.'.files'; 
    } 
    else { 
        print "Cannot obtain URL for getting files\n" if ($debug);
        return 0; 
    }
    my $content = get_page($filesUrl);
    my $files = 0;
    while ( $content =~ /<tr><td>/g ) {
        $files++;
    }
    print "Found that torrent contains $files files\n" if ($debug);
    return $files;
}

sub get_page {
    my $url = shift;
    my $ua = LWP::UserAgent->new;
    $ua->agent($cfg{'user-agent'}) if ($cfg{'user-agent'});

    print "Send GET to $url\n" if ($debug);
    my $req = $ua->get($url);
    print "Got ".$req->{_rc}." ".$req->{_msg}."\n" if ($debug);
    return $req->decoded_content( charset => 'utf8' );
}

sub parse_page {
    my $content = shift;
    print "Seeking for torrent URL\n" if ($debug);
    if ($content =~ /<a href="([^\"]+)"><img src="[^\"]+down\.png">/) {
        print "Got URL $1\n" if ($debug);
        return $1;
    }
    print "URL was not found\n" if ($debug);
    return;
}

sub parse_list {
    my ($file, $list) = @_;
    open (LST, "$file") || die "ERROR: Could not open list file : $list";
    while (<LST>) {
        my $line = lc($_);
        chop ($line);
        $line =~ s/^\s*//;
        $line =~ s/\s*$//;
        next if ($line =~ /^#/ || !$line);
        if ($line =~ /^(.+)\|(\d+)/) {
            $$list{$1}->{files} = $2;
        }
        else {
            $$list{$line}->{files} = 0;
        }
    }
    close(LST);
}

sub update_list {
    my ($file, $name, $files) = @_;
    my $tmpFile = $file.'.swp';
    unlink ($tmpFile);
    open (IN, '<', $file) || die "Cannot open file '$file' for reading";
    open (OUT, '>', $tmpFile) || die "Cannot open file '$tmpFile' for writing";
    while (<IN>) {
        chomp;
        if (/${name}($|\|)/i) {
            print OUT $name."|$files\n";
            print "Modified list string as ".$name."|$files\n" if ($debug);
        }
        else {
            print OUT $_."\n";
        }
    }
    close IN;
    close OUT;
    rename $tmpFile, $file;
}

sub script_dir {
    my $path = realpath($0);
    if ($path =~ /^(.+)\/[^\/]+$/) {
        return $1;
    }
    return $path;
}

sub parse_config {
    my ($file, $config) = @_;
    my $block;

    open (CFG, "$file") || die "ERROR: Could not open config file : $file";

    while (<CFG>) {
        my $line = $_;
        chop ($line);
        $line =~ s/^\s*//;
        $line =~ s/\s*$//;
        if ($line =~ /^\[(.+)\]$/) {
            $block = $1;
            next;
        }
        elsif ( ($line !~ /^#/) && ($line =~ /^(.*\S)\s*\=\s*(\S.*)$/) ) {
            if ($block) {
                $$config{$block}->{$1} = $2;
            } else {
                $$config{$1} = $2;
            }
        }
    }

    close(CFG);
}

