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
    my $torrent = check_torrent($url,$list{$url}->{bytes});
    if ($torrent && drag_torrent($torrent->{url},$torrentDir)) {
        print "Changing list file\n" if ($debug);
        update_list($scriptDir.'/'.$listFile,$url,$torrent->{bytes});
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

sub check_torrent {
    my ($url,$bytes) = @_;
    $url = 'http://'.$cfg{rutor}->{domain}.$url;
    my $ua = LWP::UserAgent->new;
    $ua->agent($cfg{'user-agent'}) if ($cfg{'user-agent'});

    print "Send GET to $url\n" if ($debug);
    my $req = $ua->get($url);
    print "Got ".$req->{_rc}." ".$req->{_msg}."\n" if ($debug);
    my $torrent = parse_page($req->decoded_content( charset => 'utf8' ),$bytes);
    return $torrent; 
}

sub parse_page {
    my ($content,$prevBytes) = @_;
    if ($content =~ /\((\d+) Bytes\)/) {
        my $newBytes = $1;
        if ($prevBytes == $newBytes) {
            print "Content size haven't changed. Skip this torrent\n" if ($debug);
            return;
        }
        print "Content size have changed. Seeking for torrent URL\n" if ($debug);
        if ($content =~ /<a href="([^\"]+)"><img src="[^\"]+down\.png">/) {
            my %res = ( url => $1,
                        bytes => $newBytes );
            print "Got URL $1 with Bytes $newBytes\n" if ($debug);
            return \%res;
        }
        print "URL was not found\n" if ($debug);
        return;
    }
    print "Content size cannot be fetched from page\n";
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
            $$list{$1}->{bytes} = $2;
        }
        else {
            $$list{$line}->{bytes} = 0;
        }
    }
    close(LST);
}

sub update_list {
    my ($file, $name, $bytes) = @_;
    my $tmpFile = $file.'.swp';
    unlink ($tmpFile);
    open (IN, '<', $file) || die "Cannot open file '$file' for reading";
    open (OUT, '>', $tmpFile) || die "Cannot open file '$tmpFile' for writing";
    while (<IN>) {
        chomp;
        if (/${name}($|\|)/i) {
            print OUT $name."|$bytes\n";
            print "Modified list string as ".$name."|$bytes\n" if ($debug);
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

