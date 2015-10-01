#!/usr/bin/perl
$ENV{PERL_LWP_SSL_VERIFY_HOSTNAME} = 0;
use warnings;
use strict;
binmode(STDOUT,':utf8');
use LWP::UserAgent;
use Cwd	qw( realpath );

use Data::Dumper;

my $configFile = 'dragger.cfg';
my $cookieFile = 'lostfilm.cookie';
my $listFile = 'lostfilm.list';

our %cfg;
our %list;

my $scriptDir = script_dir();
parse_config($scriptDir.'/'.$configFile, \%cfg);
parse_list($scriptDir.'/'.$listFile, \%list);

our $debug = $cfg{debug};

my $cookie = read_cookie($scriptDir.'/'.$cookieFile);

unless($cookie) {
    print "Cannot get cookie!\n";
    exit;
}

my @torrents;
my $torrentDir = $cfg{'torrent-dir'}||$scriptDir;
find_new_episodes($cookie,$scriptDir.'/'.$cookieFile, \@torrents);
foreach (@torrents) {
    print "Getting torrent URL for $_->{name}\n" if ($debug);
    my $torrentUrl = get_torrent_url($_->{id},$_->{season},$_->{ep},$cookie);
    if (drag_torrent($torrentUrl,$torrentDir)) {
        print "Changing list file\n" if ($debug);
        update_list($scriptDir.'/'.$listFile,$_->{name},$_->{season},$_->{ep});
    }
}

exit;

sub drag_torrent {
    my ($url,$dir) = @_;
    return unless ($url && $dir);
    my $ua = LWP::UserAgent->new;
    $ua->agent($cfg{'user-agent'}) if ($cfg{'user-agent'});
    print "Send GET to $url\n" if ($debug);
    my $req = $ua->get($url);
    print "Got ".$req->{_rc}." ".$req->{_msg}."\n" if ($debug);
    my $contentDisposition = $req->{_headers}->{'content-disposition'};
    if ($contentDisposition =~ /filename="(.+?)"/) {
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

sub log_in {
    my $ua = LWP::UserAgent->new;
    $ua->agent($cfg{'user-agent'}) if ($cfg{'user-agent'});
    my ($req,$cookie);

    my $urlPostLogin = 'http://login1.bogi.ru/login.php?referer=http%3A%2F%2Fwww.lostfilm.tv%2F';

    # Отправляем POST на логин на bogi.ru
    print "Sending POST to $urlPostLogin\n" if ($debug);
    $req = $ua->post($urlPostLogin,
        [
		'login'		=> $cfg{lostfilm}->{login},
		'password'	=> $cfg{lostfilm}->{pwd},
		'module'	=> 1,
		'target'	=> 'http%3A%2F%2Flostfilm.tv%2F',
		'repage'	=> 'user',
		'act'		=> 'login',
        ]
    );

    print "Got ".$req->{_rc}." ".$req->{_msg}."\n" if ($debug);

    # Парсим форму для отправки на lostfilm.tv
    my $content = $req->{_content};
    my $urlPostLF;
    my %formInputs;
    if ($content =~ /action=\"(.+?)\"/) {
        $urlPostLF = $1;
	$urlPostLF =~ s/^\/\//http:\/\//;
        print "Parsed URL $urlPostLF from response\n" if ($debug);
    }
    while ($content =~ /<input.+?name="(.+?)".+?value="(.*?)" \/>/g) {
        $formInputs{$1}=$2;
    }

    print "Sending POST to $urlPostLF\n" if ($debug);
    $formInputs{iehack}='☠',
    print Dumper(\%formInputs) if ($debug);

    # Отправляем форму на lostfilm.tv
    $req = $ua->post($urlPostLF,
        'Content' => \%formInputs,
        'referer' => 'http://login1.bogi.ru/login.php?referer=http%3A%2F%2Fwww.lostfilm.tv%2F',
        'Accept-Encoding' => 'gzip, deflate',
        'connection' => 'keep-alive',
        'accept' => 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'accept-language' => 'en-US,en;q=0.5'
    );

    $cookie = $req->{_headers}->{'set-cookie'};
    print "Got ".$req->{_rc}." ".$req->{_msg}."\n" if ($debug);
    #print $req->decoded_content;

    unless($req->{_rc} == 302 && $cookie) { return; }
    # Выкусываем нужные cookie из заголовка Set-Cookie
    $cookie = set_cookie($cookie);
    return $cookie;
}

sub set_cookie {
    my $setCookie = shift;
    my $cookie='';
    if (ref($setCookie) eq "SCALAR") {
        while ($setCookie =~ /(\S+\s*\=\s*\S+\;).+?domain=\.lostfilm\.tv/g) {
            $cookie.=$1;
        }
    }
    elsif (ref($setCookie) eq "ARRAY") {
        foreach (@{$setCookie}) {
            if (/(\S+\s*\=\s*\S+\;).+?domain=\.lostfilm\.tv/) {
                $cookie.=$1;
            }
        }
    }
    print "Parsed cookie $cookie\n" if ($debug);
    return $cookie;
}

sub get_torrent_url {
    my ($id,$season,$ep,$cookie) = @_;

    my $ua = LWP::UserAgent->new;
    $ua->agent($cfg{'user-agent'}) if ($cfg{'user-agent'});

    # Получаем адрес страницы с торрентами
    my $urlNrdr = "http://www.lostfilm.tv/nrdr.php?c=$id&s=$season&e=$ep";
    print "Sending GET to $urlNrdr\n" if ($debug);

    my $req = $ua->get($urlNrdr, cookie => $cookie);
    print "Got ".$req->{_rc}." ".$req->{_msg}."\n" if ($debug);
    unless ($req->{_rc} == 200) {
        print "Response code is not 200. Aborting...\n" if ($debug);
        return;
    }
    my %torrent;
    my $content = $req->decoded_content;
    while ($content =~ /<a href="(http:\/\/tracktor\.in\/.+?)" .+?>(.+?)<\/a>/g) {
        my $url = $1;
        my $descr = $2;
        next if ($descr =~ /tracktor\.in/);
        my $quality = 0;
        my $reqQuality = 0;
        if ($cfg{quality} eq 'max') { $reqQuality = 10000; }
            elsif ($cfg{quality} =~ /(\d+)p/) { $reqQuality = $1; }
        if ($descr =~ /(\d+)p/) { $quality = $1; }
        print "Found torrent $descr (quality $quality)\n" if ($debug);
       	if ($quality == $reqQuality) {
           $torrent{url} = $url;
           $torrent{q} = $quality;
           last;
        }
        elsif ( !$torrent{url} ) {
           $torrent{url} = $url;
           $torrent{q} = $quality;
           next;
        }
        elsif ( $quality > $reqQuality ) {
           next;
        }
        elsif ( $quality > $torrent{q} ) {
           $torrent{url} = $url;
           $torrent{q} = $quality;
           next;
        }
    }
    unless ($torrent{url}) {
        print "No torrent found. Aborting...\n";
        return;
    }
    print "Decided to download torrent ".$torrent{url}." with quality ".$torrent{q}."\n" if ($debug);
    return($torrent{url});
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

sub parse_list {
    my ($file, $list) = @_;
    open (LST, "$file") || die "ERROR: Could not open list file : $list";
    while (<LST>) {
        my $line = lc($_);
        chop ($line);
        $line =~ s/^\s*//;
        $line =~ s/\s*$//;
        next if ($line =~ /^#/ || !$line);
        if ($line =~ /^(.+)\|s([\d\.]+)e([\d\.]+)/) {
            $$list{$1}->{season} = $2;
            $$list{$1}->{ep} = $3;
        }
        else {
            $$list{$line}->{season} = 0;
            $$list{$line}->{ep} = 0;
        }
    }
    close(LST);
}

sub update_list {
    my ($file, $name, $season, $ep) = @_;
    my $tmpFile = $file.'.swp';
    unlink ($tmpFile);
    open (IN, '<', $file) || die "Cannot open file '$file' for reading";
    open (OUT, '>', $tmpFile) || die "Cannot open file '$tmpFile' for writing";
    while (<IN>) {
        chomp;
        if (/${name}($|\|)/i) {
            print OUT $name."|s${season}e${ep}\n";
            print "Modified list string as ".$name."|s${season}e${ep}\n" if ($debug);
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

sub read_cookie {
    my $file = shift;
    my $cookie;
    if (open(COOKIE,$file)) {
        $cookie = <COOKIE>;
        close COOKIE;
    }
    if ($cookie) { return $cookie; }
    print "Could not read cookie. Going to login\n" if ($debug);
    $cookie = log_in();    
    write_cookie($cookie, $file) if ($cookie && $file);
    return $cookie;
}

sub write_cookie {
    my ($cookie,$file) = @_;
    print "Got cookie $cookie. Writing it to a file $file\n" if ($debug);    
    open(COOKIE, ">".$file) || die "Cannot write to cookie file $file";
    print COOKIE $cookie;
    return;
}

sub find_new_episodes {
    my ($cookie,$cookieFile,$torrents) = @_;   

    my $ua = LWP::UserAgent->new;
    $ua->agent($cfg{'user-agent'}) if ($cfg{'user-agent'});

    my $urlBrowse = 'http://www.lostfilm.tv/browse.php';
    print "Sending GET to $urlBrowse\n" if ($debug);

    my $req = $ua->get($urlBrowse, cookie => $cookie);
    print "Got ".$req->{_rc}." ".$req->{_msg}."\n" if ($debug);
    unless ($req->{_rc} == 200) {
        print "Cannot GET page $urlBrowse\n";
        exit;
    }   
    my $content = $req->decoded_content; 
    my $seriesCount;
    while ($content =~ /a href=\"\/download\.php\?id=\d+&(\S+)\.S(\d+)E(\d+)[\s\S]{1,400}?ShowAllReleases\('_?(\d+)','([\.\d]+)','(\d+)'/g) {
        $seriesCount++;
	my $name = lc($1);
        my $s = $5;
        my $e = $6;
        my $id = $4;
        $name =~ s/\./ /g;
        my $pointer = '';
        
        # Если сериал есть в списке
        if ($list{$name}) {
            $pointer = '<----';
            if ( ($list{$name}->{season} < $s) || ($list{$name}->{season} == $s && $list{$name}->{ep} < $e) ) {
                $pointer .= ' drag it';
                my %torrent;
                $torrent{id} = $id;
                $torrent{name} = $name;
                $torrent{season} = $s;
                $torrent{ep} = $e;
                push(@{$torrents}, \%torrent);
            }
            else {
                $pointer .= 'got it already';
            }
        } 

        print "Found $name $s $e $id\t\t$pointer\n" if ($debug);
    }
    if ( !$seriesCount && ($content =~ /id="login-button"/i) ) {
        print "Not logged in. Trying to relogin\n" if ($debug);
        $cookie = log_in();
        write_cookie($cookie, $cookieFile) if ($cookie && $cookieFile);
        exit;
    }
    elsif ( !$seriesCount ) {
        print "Cannot parse list\n" if ($debug);
    }
}
