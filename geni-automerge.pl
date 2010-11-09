#!/usr/bin/perl

use strict;
use WWW::Mechanize;
use HTTP::Cookies;
use Class::Struct;
use IO::File;
use Time::HiRes;
use JSON;
# http://search.cpan.org/~maurice/Text-DoubleMetaphone-0.07/DoubleMetaphone.pm
use Text::DoubleMetaphone qw( double_metaphone );

# globals and constants
my (%env, %debug, $debug_fh, $merge_log_fh, $m, %blacklist_managers, @get_history, $name_list_fh);
my $m = WWW::Mechanize->new(autocheck => 0);
my $DBG_NONE			= "DBG_NONE"; # Normal output
my $DBG_PROGRESS		= "DBG_PROGRESS";
my $DBG_URLS			= "DBG_URLS";
my $DBG_IO			= "DBG_IO";
my $DBG_NAMES			= "DBG_NAMES";
my $DBG_JSON			= "DBG_JSON";
my $DBG_PHONETICS		= "DBG_PHONETICS";
my $DBG_MATCH_DATE		= "DBG_MATCH_DATE";
my $DBG_MATCH_BASIC		= "DBG_MATCH_BASIC";

init();
main();

sub init(){
	# configuration
	$env{'circa_range'}		= 5;
	$env{'get_timeframe'}		= 10;
	$env{'get_limit'}		= 18; # Amos has the limit set to 20 so we'll use 18 to have some breathing room
	$env{'datadir'} 		= "script_data";
	$env{'logdir'}			= "logs";
	$env{'action'}			= "traverse_pending_merges";

	# environment
	$env{'start_time'}		= time();
	$env{'logged_in'}		= 0;
	# todo: Once we are all running this script from the same machine
	# merge_log_file needs to be the same file for all users.
	$env{'merge_log_file'}		= "$env{'logdir'}/merge_log.html";
	$env{'name_list_file'}		= "$env{'logdir'}/name_list.txt";
	$env{'log_file'}		= "$env{'logdir'}/logfile_" . dateHourMinuteSecond() . ".html";
	$env{'matches'} 		= 0;
	$env{'profiles'}		= 0;

	# logging
	(mkdir $env{'datadir'}, 0755) if !(-e $env{'datadir'});
	(mkdir $env{'logdir'}, 0755) if !(-e $env{'logdir'});

	$merge_log_fh				= createWriteFH("Merge History", $env{'merge_log_file'}, 1);
	$merge_log_fh->autoflush(1);
	$name_list_fh				= createWriteFH("Name List", $env{'name_list_file'}, 1);
	$name_list_fh->autoflush(1);
	$debug_fh				= createWriteFH("logfile", $env{'log_file'}, 0);
	$debug_fh->autoflush(1);
	$debug{"file_" . $DBG_NONE}		= 1;
	$debug{"file_" . $DBG_PROGRESS}		= 1;
	$debug{"file_" . $DBG_IO}		= 0;
	$debug{"file_" . $DBG_URLS}		= 1;
	$debug{"file_" . $DBG_NAMES}		= 1;
	$debug{"file_" . $DBG_JSON}		= 0;
	$debug{"file_" . $DBG_PHONETICS}	= 0;
	$debug{"file_" . $DBG_MATCH_BASIC}	= 1;
	$debug{"file_" . $DBG_MATCH_DATE}	= 1;
	$debug{"console_" . $DBG_NONE}		= 0;
	$debug{"console_" . $DBG_PROGRESS}	= 1;
	$debug{"console_" . $DBG_IO}		= 0;
	$debug{"console_" . $DBG_URLS}		= 0;
	$debug{"console_" . $DBG_NAMES}		= 0;
	$debug{"console_" . $DBG_JSON}		= 0;
	$debug{"console_" . $DBG_PHONETICS}	= 0;
	$debug{"console_" . $DBG_MATCH_BASIC}	= 0;
	$debug{"console_" . $DBG_MATCH_DATE}	= 0;

	struct (profile => {
		name_first		=> '$',
		name_middle		=> '$',
		name_last		=> '$',
		name_maiden		=> '$',
		suffix			=> '$',
		gender			=> '$',
		living			=> '$',
		birth_year		=> '$',
		birth_date		=> '$',
		birth_location		=> '$',
		death_year		=> '$',
		death_date		=> '$',
		death_location		=> '$',
		id			=> '$',
		fathers			=> '$',
		mothers			=> '$',
		spouses			=> '$'
	});

	# It is a long story but for now don't merge profiles managed by the following:
	# http://www.geni.com/people/Wendy-Hynes/6000000003753338015#/tab/overview
	# http://www.geni.com/people/Alan-Sciascia/6000000009948172621#/tab/overview
	$blacklist_managers{"6000000003753338015"} = 1;
	$blacklist_managers{"6000000009948172621"} = 1;
}


#
# Print the syntax for running the script including all command line options
#
sub printHelp() {
	print STDERR "\nmerge_dr.pl\n\n";
	print STDERR "-u \"user\@email.com\"\n";
	print STDERR "-p password\n";
	print STDERR "-circa X (optional): X defines the number of +/- years for date matching.  5 is the default\n";
	print STDERR "-rb X (optional): rb is short for -range_begin, X is the starting page\n";
	print STDERR "-re X (optional): re is short for -range_end, X is the ending page\n";
	print STDERR "-pm X Y: pm is short for -pendingmerge.  X and Y are the two profile IDs to merge\n";
	print STDERR "-h -help : print this menu\n\n";
	print STDERR "\n";
	exit(0);
}

#
# Print debug output to STDERR and to the logfile
#
sub printDebug($$) {
	my $debug_flag = shift;
	my $msg = shift;
	if ($debug{"console_" . $debug_flag}) {
		print STDERR $msg;
	}
	if ($debug{"file_" . $debug_flag} && $debug_fh) {
		print $debug_fh $msg;
	}
}

#
# Print the die_message and logout of geni
#
sub gracefulExit($) {
	my $msg = shift;
	printDebug($DBG_NONE, "$env{'matches'} matches out of $env{'profiles'} profiles\n");
	printDebug($DBG_NONE, $msg);
	geniLogout();
	exit();
}

#
# Create a FH for reading a file and return that FH
#
sub createReadFH($) {
	my $filename = shift;
	my $fh = new IO::File;
	$fh->open("$filename", "r") || gracefulExit("\n\nERROR: createReadFH could not open '$filename'\n\n");
	return $fh;
}

#
# Create a FH for writing to a file and return that FH
#
sub createWriteFH($$$) {
	my $debug_msg = shift;
	my $filename = shift;
	my $append = shift;

	my $fh = new IO::File;
	if ($append) {
		$fh->open(">> $filename") || gracefulExit("\n\nERROR: createWriteFH could not open append '$filename'\n\n");
		printDebug($DBG_NONE, "$debug_msg: Appending to '$filename'\n") if $debug_msg;
	} else {
		$fh->open("> $filename") || gracefulExit("\n\nERROR: createWriteFH could not open '$filename'\n\n");
		printDebug($DBG_NONE, "$debug_msg: Creating '$filename'\n") if $debug_msg;
	}
	return $fh;
}

sub prependZero($) {
	my $num = shift;
	return $num =~ /^\d$/ ? "0" . $num : $num;
}

sub dateHourMinuteSecond() {
	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime();
	$year += 1900;
	$mon += 1;
	$mon  = prependZero($mon);
	$mday = prependZero($mday);
	$hour = prependZero($hour);
	$min  = prependZero($min);
	$sec  = prependZero($sec);

	return "$year\_$mon\_$mday\_$hour\_$min\_$sec";
}

sub todaysDate() {
	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime();
	$year += 1900;
	$mon += 1;
	$mon  = prependZero($mon);
	$mday = prependZero($mday);

	return "$year\_$mon\_$mday";
}

# This isn't working yet
sub geniLoginAPI() {
	if (!$env{'username'}) {
		print STDERR "\nERROR: username is blank.  You must specify your geni username via '-u username'\n";
		exit();
	}

	if (!$env{'password'}) {
		print STDERR "\nERROR: password is blank.  You must specify your geni password via '-p password'\n";
		exit();
	}

	$env{'logged_in'} = 1;
	$m->cookie_jar(HTTP::Cookies->new());
	$m->post("https://www.geni.com/login/in&username=$env{'username'}&password=$env{'password'}");
}

#
# Do a secure login into geni
#
sub geniLogin() {
	if (!$env{'username'}) {
		print STDERR "\nERROR: username is blank.  You must specify your geni username via '-u username'\n";
		exit();
	}

	if (!$env{'password'}) {
		print STDERR "\nERROR: password is blank.  You must specify your geni password via '-p password'\n";
		exit();
	}

	$m->cookie_jar(HTTP::Cookies->new());
	$m->get("https://www.geni.com/login");
	$m->form_number(2);
	$m->field("profile[username]" => $env{'username'});
	$m->field("profile[password]" => $env{'password'});
	$m->click();
	
	my $login_fh = createWriteFH("", "$env{'datadir'}/login.html", 0);
	my $output = $m->content();
	print $login_fh $output;
	undef $login_fh;

	if ($output =~ /Welcome to Geni/i) {
		printDebug($DBG_NONE, "ERROR: Login FAILED for www.geni.com!!\n");
		exit();
	}

	$env{'logged_in'} = 1;
	printDebug($DBG_NONE, "Login PASSED for www.geni.com!!\n");
}

#
# Logout of geni
#
sub geniLogout() {
	return if !$env{'logged_in'};
	printDebug($DBG_NONE, "Logging out of www.geni.com\n");
	$m->get("http://www.geni.com/logout?ref=ph");
}

sub jsonSanityCheck($) {
	my $filename = shift;

	my $fh = createReadFH($filename);
	my $json_data = <$fh>;
	undef $fh;

	# We "should" never hit this
	if ($json_data =~ /Rate limit exceeded/i) {
		printDebug($DBG_PROGRESS, "ERROR: 'Rate limit exceeded' for '$filename'\n");
		sleep(10);
		return 0;
	}

	# Some profiles are private and we cannot access them
	return if $json_data =~ /Access denied/i;

	# I've only seen this once.  Not sure what the trigger is or if the
	# sleep will fix it.
	if ($json_data =~ /500 read timeout/i) {
		sleep(10);
		return 0;
	}

	if ($json_data =~ /DOCTYPE HTML PUBLIC/) {
		printDebug($DBG_NONE, "ERROR: 'DOCTYPE HTML PUBLIC' for '$filename'\n");
		return 0;
	}

	if ($json_data =~/tatus read failed/) {
		printDebug($DBG_NONE, "ERROR: 'Status read failed' for '$filename'\n");
		return 0;
	}

	if ($json_data =~/an't connect to www/) {
		printDebug($DBG_NONE, "ERROR: 'Can't connect to www' for '$filename'\n");
		return 0;
	}

	# This should catch any other hosed json file before we hand it to the JSON
	# code which will crash the script when it sees the corrupted data.
	if ($json_data !~ /^\[\{.*\}\]$/ && $json_data !~ /^\{.*\}$/) {
		printDebug($DBG_NONE, "ERROR: Unknown json format '$json_data' for '$filename'\n");
		return 0;
	}

	return 1;
}

#
# Return TRUE if $time_A and $time_B are within $threshold of each other.
# $threshold should be in seconds.
#
# Always pass the most recent time as time_A. The time strings look like:
# EpochSeconds.Microseconds
# 1288721911.894155
# 1288721917.83155
# 1288721923.200155
# 1288721928.390155
#
sub timesInRange($$$) {
	my $time_A = shift;
	my $time_B = shift;
	my $threshold = shift;

	gracefulExit("ERROR: Don't call timesInRange with a threshold of 0\n") if !$threshold;

	(my $time_A_sec, my $time_A_usec) = split(/\./, $time_A);
	(my $time_B_sec, my $time_B_usec) = split(/\./, $time_B);

	my $delta = 0;

	if ($time_A_sec == $time_B_sec) {
		$delta += $time_A_usec - $time_B_usec;
	} else {
		my $whole_seconds_delta = ($time_A_sec - $time_B_sec) - 1;
		if ($whole_seconds_delta >= 1) {
			$delta += ($whole_seconds_delta * 1000000);
		}

		$delta += $time_A_usec;
		$delta += (1000000 - $time_B_usec);
	}

	return 1 if $delta <= ($threshold * 1000000);
	return 0;
}

sub getPage($$) {
	my $filename = shift;
	my $url = shift;

	if (-e "$filename") {
		printDebug($DBG_IO, "getPage(cached): $url\n");
		return;
	}

	geniLogin() if !$env{'logged_in'};

	printDebug($DBG_IO, "getPage(fetch): $url\n");

	(my $time_sec, my $time_usec) = Time::HiRes::gettimeofday();
	my $time_current = "$time_sec.$time_usec";

	my @new_get_history;
	my $gets_in_last_ten_seconds = 0;
	foreach my $timestamp (@get_history) {
		chomp($timestamp);
		if (timesInRange($time_current, $timestamp, $env{'get_timeframe'})) {
			$gets_in_last_ten_seconds++;
			push @new_get_history, $timestamp;
		}
	}
	@get_history = @new_get_history;

	if ($gets_in_last_ten_seconds >= $env{'get_limit'}) {
		printDebug($DBG_NONE, "$gets_in_last_ten_seconds gets() in the past $env{'get_timeframe'} seconds....sleeping....\n");
		sleep(1);
	}

	my $fh = createWriteFH("", $filename, 0);
	$m->get($url);
	print $fh $m->content();
	undef $fh;

	updateGetHistory();
}

#
# Return TRUE if year1 or year2 were marked with circa and fall within +/- 5 years of each other.
# Else only return TRUE if they match exactly
#
sub yearInRange($$$) {
	my $year1 = shift;
	my $year2 = shift;
	my $circa = shift;

	return (abs(($year1) - ($year2)) <= $env{'circa_range'} ? $env{'circa_range'} : 0) if $circa;
	return ($year1 == $year2); 
}

sub monthDayYear($) {
	my $date = shift;

	my $date_month = 0;
	my $date_day = 0;
	my $date_year = 0;

	# 7/1/1700
	if ($date =~ /(\d+)\/(\d+)\/(\d+)/) {
		$date_month	= $1;
		$date_day	= $2;
		$date_year	= $3;

	# July 1700
	} elsif ($date =~ /(\w+) (\d+)/) {
		$date_month = $1;
		$date_year  = $2;
			  if ($date_month =~ /jan/i) { $date_month = 1;
		} elsif ($date_month =~ /feb/i) { $date_month = 2;
		} elsif ($date_month =~ /mar/i) { $date_month = 3;
		} elsif ($date_month =~ /apr/i) { $date_month = 4;
		} elsif ($date_month =~ /may/i) { $date_month = 5;
		} elsif ($date_month =~ /jun/i) { $date_month = 6;
		} elsif ($date_month =~ /jul/i) { $date_month = 7;
		} elsif ($date_month =~ /aug/i) { $date_month = 8;
		} elsif ($date_month =~ /sep/i) { $date_month = 9;
		} elsif ($date_month =~ /oct/i) { $date_month = 10;
		} elsif ($date_month =~ /nov/i) { $date_month = 11;
		} elsif ($date_month =~ /dec/i) { $date_month = 12;
		}

	# 1700
	} elsif ($date =~ /(\d+)/) {
		$date_year  = $1;

	# July
	} elsif ($date =~ /(\w+)/) {
		$date_month = $1;
			  if ($date_month =~ /jan/i) { $date_month = 1;
		} elsif ($date_month =~ /feb/i) { $date_month = 2;
		} elsif ($date_month =~ /mar/i) { $date_month = 3;
		} elsif ($date_month =~ /apr/i) { $date_month = 4;
		} elsif ($date_month =~ /may/i) { $date_month = 5;
		} elsif ($date_month =~ /jun/i) { $date_month = 6;
		} elsif ($date_month =~ /jul/i) { $date_month = 7;
		} elsif ($date_month =~ /aug/i) { $date_month = 8;
		} elsif ($date_month =~ /sep/i) { $date_month = 9;
		} elsif ($date_month =~ /oct/i) { $date_month = 10;
		} elsif ($date_month =~ /nov/i) { $date_month = 11;
		} elsif ($date_month =~ /dec/i) { $date_month = 12;
		}

	}

	return ($date_month, $date_day, $date_year);
}

#
# Return true if the dates match or if one is a more specific date within the same year
#
sub dateMatches($$) {
	my $date1 = shift;
	my $date2 = shift;

	if ($date1 eq $date2) {
		# To reduce debug output, don't print the debug when both are "" 
		printDebug($DBG_MATCH_DATE, "DATES: date1 ($date1), date2($date2) MATCHED\n") if $date1 ne "";
		return 1;
	}

	printDebug($DBG_MATCH_DATE, "DATES: date1 ($date1), date2($date2)");

	# If one date is blank and the other is not then we consider one to be more specific than the other
	if (($date1 ne "" && $date2 eq "") ||
		 ($date1 eq "" && $date2 ne "")) {
		printDebug($DBG_MATCH_DATE, "  MATCHED\n");
		return 1;
	} 

	my $date1_month = 0;
	my $date1_day	= 0;
	my $date1_year  = 0;
	my $date2_month = 0;
	my $date2_day	= 0;
	my $date2_year  = 0;
	my $circa	= 0;

	# Remove the circa "c."
	if ($date1 =~ /c\.\s+(.*?)$/) {
		$circa = 1;
		$date1 = $1;
	}

	# Remove the circa "c."
	if ($date2 =~ /c\.\s+(.*?)$/) {
		$circa = 1;
		$date2 = $1;
	}

	($date1_month, $date1_day, $date1_year) = monthDayYear($date1);
	($date2_month, $date2_day, $date2_year) = monthDayYear($date2);

	# If the year is pre 1750 then assume circa.  If you don't do this there are too many dates that
	# are off by a year or two that never match
	if ($circa == 0 &&
		(($date1_year != 0 && $date1_year <= 1750) ||
		($date2_year != 0 && $date2_year <= 1750))) {
		$circa = 1;
	}

	printDebug($DBG_MATCH_DATE, "\n date1_month: $date1_month\n");
	printDebug($DBG_MATCH_DATE, " date1_day  : $date1_day\n");
	printDebug($DBG_MATCH_DATE, " date1_year : $date1_year\n");
	printDebug($DBG_MATCH_DATE, " date2_month: $date2_month\n");
	printDebug($DBG_MATCH_DATE, " date2_day  : $date2_day\n");
	printDebug($DBG_MATCH_DATE, " date2_year : $date2_year\n");
	printDebug($DBG_MATCH_DATE, " circa      : $circa\n\n");

	if (yearInRange($date1_year, $date2_year, $circa)) {
		if ($date1_month && $date2_month && $date1_month == $date2_month) {
			if ($date1_day && $date2_day && $date1_day == $date2_day) {
				printDebug($DBG_MATCH_DATE, "  MATCHED\n");
				return 1;
			}
		}
	}

	printDebug($DBG_MATCH_DATE, "  DID NOT MATCH\n");
	return 0;
}

sub cleanupNameGuts($) {
	my $name = shift;
	$name = lc($name);

	# Remove everything in ""s
	while ($name =~ /\".*?\"/) {
		$name = $` . " " . $';
	}

	# Remove everything in ''s
	while ($name =~ /\'.*?\'/) {
		$name = $` . " " . $';
	}

	# Remove everything in ()s
	while ($name =~ /\(.*?\)/) {
		$name = $` . " " . $';
	}

	# Remove everything in []s
	while ($name =~ /\[.*?\]/) {
		$name = $` . " " . $';
	}

	# Remove punctuation
	$name =~ s/\./ /g;
	$name =~ s/\,/ /g;
	$name =~ s/\'/ /g;
	$name =~ s/\^/ /g;
	$name =~ s/\// /g;
	$name =~ s/\\/ /g;
	$name =~ s/\(/ /g; # Note: If there were a ( and ) they would have already been removed
	$name =~ s/\)/ /g; # but it is possible to have one or the other

	# Remove 1st, 2nd, 3rd, 1900, 1750, etc
	if ($name =~ /\b\d+(st|nd|rd|th)*\b/) {
		$name = $` . " " . $';
	}

	my @strings_to_remove = ("di", "de", "of", "av", "la", "le", "du",
				"nn", "unknown", "<unknown>", "unk",
				"daughter", "dau", "wife", "mr", "mrs", "miss", "duchess",
				"lord", "duke", "earl", "prince", "princess", "king", "queen", "baron",
				"csa", "general", "gen", "president", "pres", "countess", "lieutenant", "lt",
				"captain", "chief justice", "honorable", "hon",
				"ii", "iii", "iv", "vi", "vii", "viii", "iix", "ix",
				"sir", "knight", "reverend", "rev", "count", "ct", "cnt", "sheriff",
				"jr", "sr", "junior", "senior");
	foreach my $rm_string (@strings_to_remove) {
		while ($name =~ /^$rm_string /) {
			$name = $';
		}
		while ($name =~ / $rm_string$/) {
			$name = $`;
		}
		while ($name =~ / $rm_string /) {
			$name = $` . " " . $';
		}
	}

	# Remove double (or more) whitespaces
	while ($name =~ /\s\s/) {
		$name = $` . " " . $';
	}

	# Remove leading whitespaces
	$name =~ s/^\s+//;

	# Remove trailing whitespaces
	$name =~ s/\s+$//;

	# Combine repeating words in a name like "Robert Robert" or
	# "tiberius claudius nero claudius tiberius claudius nero" 
	my @final_name;
	my %name_components;
	foreach my $i(split(/ /, $name)) {
		if (!(exists $name_components{$i})) {
			$name_components{$i} = 1;
			push @final_name, $i;
		}
	}
	return join(" ", @final_name);
}

#
# Construct names consistently 
#
sub cleanupName($$$$) {
	my $first	= shift;
	my $middle	= shift;
	my $last	= shift;
	my $maiden	= shift;
	my $name	= "";

	printDebug($DBG_NAMES, "cleanupName: Initial Name: first '$first', middle '$middle', last '$last', maiden '$maiden'\n");
	$name = $first if $first;
	$name .= " $middle" if $middle;
	$name .= " $last" if $last;

	$name = cleanupNameGuts($name);
	$maiden = cleanupNameGuts($maiden);
	$name .= " ($maiden)" if $maiden;

	printDebug($DBG_NAMES, "cleanupName: Standardized name '$name'\n\n");
	return $name;
}

# Return TRUE if they match
sub initialVsWholeMatch($$) {
	my $left_name	= shift;
	my $right_name	= shift;

	# If one profile has the name "M" and the other has "Mark" then we
	# should consider that a match.
	if ($left_name =~ /^\w$/) {
		return ($right_name =~ /^$left_name/);
	} elsif ($right_name =~ /^\w$/) {
		return ($left_name =~ /^$right_name/);
	}

	return 0;
}

sub oddCharCount($) {
	my $name = shift;
	my $odd_char_count = 0;
	foreach my $char (split(//, $name)) {
		if ($char !~ /^\w$/) {
			$odd_char_count++;
		}
	}
	return $odd_char_count;
}

sub doubleMetaphoneCompare($$) {
	my $left_name	= shift;
	my $right_name	= shift;

	# Sometimes middle names will be really long and consist of multiple words.
	# Double metaphone only looks at the first four syllables so comparing two
	# names with multiple words could give false positives.  Better to be safe
	# and just declare them not a match.
	return 0 if ($left_name =~ / / || $right_name =~ / /);

	# This should never happen but just to be safe
	return 0 if ($left_name eq "" || $right_name eq "");

	# If one of the names is just an initial then bail out
	return 0 if ($left_name =~ /^.$/ || $right_name =~ /^.$/);

	# Non-english names give too many false positives so if the name is full
	# of funky characters then don't even bother running metaphone.
	return 0 if (oddCharCount($left_name) > 2 || oddCharCount($right_name) > 2);

	(my $left_code1, my $left_code2) = double_metaphone($left_name);
	(my $right_code1, my $right_code2) = double_metaphone($right_name);
	#printf("\n%s: %s %s\n", $left_name, $left_code1, $left_code2);
	#printf("%s: %s %s\n", $right_name, $right_code1, $right_code2);

	return (($left_code1 eq $right_code1) || ($left_code1 eq $right_code2) || ($left_code2 eq $right_code1) ||
		($left_code2 eq $right_code2 && $left_code2));
}

sub compareNamesGuts($$$) {
	my $compare_initials = shift;
	my $left_name	= shift;
	my $right_name	= shift;

	return 1 if $left_name && !$right_name;
	return 1 if !$left_name && $right_name;
	return 1 if $left_name eq $right_name;
	return 1 if $compare_initials && initialVsWholeMatch($left_name, $right_name);
	return 1 if doubleMetaphoneCompare($left_name, $right_name);
	return 0;
}

# Return TRUE if they match
sub compareNames($$$) {
	my $gender	= shift;
	my $left_name	= shift;
	my $right_name	= shift;

	if (($left_name && !$right_name) ||
	    (!$left_name && $right_name) ||
	    ($left_name eq $right_name)) {
		return 1;
	}

	my $left_name_first	= "";
	my $left_name_middle	= "";
	my $left_name_last	= "";
	my $left_name_maiden	= "";

	if ($left_name =~ / \((.*)\)$/) {
		$left_name_maiden = $1;
		$left_name = $`;
	}

	if ($left_name =~ /^(\w+)\s(\w+)\s(\w+)$/) {
		$left_name_first = $1;
		$left_name_middle = $2;
		$left_name_last= $3;
	} elsif ($left_name =~ /^(\w+)\s(\w+)$/) {
		$left_name_first = $1;
		$left_name_last= $2;
	} elsif ($left_name =~ /^(\w+)$/) {
		$left_name_first = $1;
	# This will happen when the profile has multiple middle names
	} elsif ($left_name =~ /^(\w+)\s(.*)\s(\w+)$/) {
		$left_name_first = $1;
		$left_name_middle = $2;
		$left_name_last= $3;
	}

	my $right_name_first	= "";
	my $right_name_middle	= "";
	my $right_name_last	= "";
	my $right_name_maiden	= "";

	if ($right_name =~ / \((.*)\)$/) {
		$right_name_maiden = $1;
		$right_name = $`;
	}

	if ($right_name =~ /^(\w+)\s(\w+)\s(\w+)$/) {
		$right_name_first = $1;
		$right_name_middle = $2;
		$right_name_last= $3;
	} elsif ($right_name =~ /^(\w+)\s(\w+)$/) {
		$right_name_first = $1;
		$right_name_last= $2;
	} elsif ($right_name =~ /^(\w+)$/) {
		$right_name_first = $1;
	# This will happen when the profile has multiple middle names
	} elsif ($right_name =~ /^(\w+)\s(.*)\s(\w+)$/) {
		$right_name_first = $1;
		$right_name_middle = $2;
		$right_name_last= $3;
	}

	# Store a list of pairs of names that we can use for phonetics testing
	if ($debug{"file__" . $DBG_PHONETICS} || $debug{"console_" . $DBG_PHONETICS}) {
		if (($left_name_first ne $right_name_first) && $left_name_first && $right_name_first) {
			print $name_list_fh "$left_name_first\:$right_name_first\n";
		}

		if (($left_name_middle ne $right_name_middle) && $left_name_middle && $right_name_middle) {
			print $name_list_fh "$left_name_middle\:$right_name_middle\n";
		}

		if (($left_name_last ne $right_name_last) && $left_name_last && $right_name_last) {
			print $name_list_fh "$left_name_last\:$right_name_last\n";
		}

		if (($left_name_maiden ne $right_name_maiden) && $left_name_maiden && $right_name_maiden) {
			print $name_list_fh "$left_name_maiden\:$right_name_maiden\n";
		}
	}

	my $first_name_matches = compareNamesGuts(1, $left_name_first, $right_name_first);
	my $middle_name_matches = compareNamesGuts(1, $left_name_middle, $right_name_middle);
	my $last_name_matches = 0;

	if ($gender eq "female") {
		$left_name_maiden = $left_name_last if ($left_name_maiden eq "");
		$right_name_maiden = $right_name_last if ($right_name_maiden eq "");
		$last_name_matches = compareNamesGuts(0, $left_name_maiden, $right_name_maiden) ||
				     compareNamesGuts(0, $left_name_last, $right_name_last);
	} else {
		$last_name_matches = compareNamesGuts(0, $left_name_last, $right_name_last);
	}

	printDebug($DBG_NAMES, "compareNames: left '$left_name ($left_name_maiden)', right '$right_name ($right_name_maiden)', first_match($first_name_matches), middle_match($middle_name_matches), last_match($last_name_matches)\n");
	return ($first_name_matches && $middle_name_matches && $last_name_matches);
}

#
# Return TRUE if the names, dates, etc for the two profiles match
#
sub profileBasicsMatch($$) {
	my $left_profile = shift;
	my $right_profile = shift;
	my $score = 0;

	my $left_name = 
		cleanupName($left_profile->name_first,
			$left_profile->name_middle,
			$left_profile->name_last,
			$left_profile->name_maiden);

	my $right_name =
		cleanupName($right_profile->name_first,
			$right_profile->name_middle,
			$right_profile->name_last,
			$right_profile->name_maiden);

	if ($left_profile->gender ne $right_profile->gender) {
		printDebug($DBG_MATCH_BASIC,
			sprintf("profileBasicsMatch(gender): %s's '%s' does not equal '%s'\n",
				$left_name,
				$left_profile->gender,
				$right_profile->gender));
		return 0;
	}

	if (!compareNames($left_profile->gender, $left_name, $right_name)) {
		printDebug($DBG_MATCH_BASIC,
			sprintf("profileBasicsMatch(name): '%s' ne '%s'\n",
				$left_name,
				$right_name));
		return 0;
	}

	if ($left_profile->living ne $right_profile->living) {
		printDebug($DBG_MATCH_BASIC,
			sprintf("profileBasicsMatch(living): %s's '%s' does not equal '%s'\n",
				$left_name,
				$left_profile->living,
				$right_profile->living));
		return 0;
	}

	if (!dateMatches($left_profile->death_year, $right_profile->death_year)) {
		printDebug($DBG_MATCH_BASIC,
			sprintf("profileBasicsMatch(death_date): %s's death year '%s' does not equal '%s'\n",
				$left_name,
				$left_profile->death_year,
				$right_profile->death_year));
		return 0;
	}

	if (!dateMatches($left_profile->death_date, $right_profile->death_date)) {
		printDebug($DBG_MATCH_BASIC,
			sprintf("profileBasicsMatch(death_date): %s's death date '%s' does not equal '%s'\n",
				$left_name,
				$left_profile->death_date,
				$right_profile->death_date));
		return 0;
	}

	if (!dateMatches($left_profile->birth_year, $right_profile->birth_year)) {
		printDebug($DBG_MATCH_BASIC,
			sprintf("profileBasicsMatch(birth_year): %s's birth year '%s' does not equal '%s'\n",
				$left_name,
				$left_profile->birth_year,
				$right_profile->birth_year));
		return 0;
	}

	if (!dateMatches($left_profile->birth_date, $right_profile->birth_date)) {
		printDebug($DBG_MATCH_BASIC,
			sprintf("profileBasicsMatch(birth_date): %s's birth date '%s' does not equal '%s'\n",
				$left_name,
				$left_profile->birth_date,
				$right_profile->birth_date));
		return 0;
	}

	printDebug($DBG_MATCH_BASIC,
		sprintf("profileBasicsMatch(name): %s's basic profile data matches\n",
			$left_name));
	return 1;
}

#
# Determine how many pages of pending merges there are.  There currently
# isn't a way to do this via the API so we screen scrape it from the html.
#
sub getMaxPendingMergesPage() {
}

sub comparePartners($$$$) {
	my $gender		= shift;
	my $partner_type	= shift;
	my $left_partners	= shift;
	my $right_partners	= shift;

	if (($left_partners && !$right_partners) || (!$left_partners && $right_partners)) { 
		return 1;
	}

	if ($left_partners ne $right_partners) { 
		foreach my $person (split(/:/, $left_partners)) {
			foreach my $person2 (split(/:/, $right_partners)) {
				if (compareNames($gender, $person, $person2)) {
					printDebug($DBG_MATCH_BASIC, "One of the $partner_type is a match.\n");
					return 1;
				}
			}
		}

		printDebug($DBG_MATCH_BASIC, "Profile $partner_type DO NOT match.\n");

		printDebug($DBG_MATCH_BASIC, "Left Profile $partner_type:\n");
		foreach my $person (split(/:/, $left_partners)) {
			printDebug($DBG_MATCH_BASIC, "- $person\n");
		}

		printDebug($DBG_MATCH_BASIC, "Right Profile $partner_type:\n");
		foreach my $person (split(/:/, $right_partners)) {
			printDebug($DBG_MATCH_BASIC, "- $person\n");
		}

		return 0;
	}

	return 1;
}

sub avoidDuplicatesPush($$$) {
	my $gender	= shift;
	my $names_array = shift;
	my $name_to_add	= shift;

	foreach my $name (@$names_array) {
		return if compareNames($gender, $name, $name_to_add);
	}
	push @$names_array, $name_to_add;
}

sub mergeURLHTML($$) {
	my $id1			= shift;
	my $id2			= shift;
	return "<a href=\"http://www.geni.com/merge/compare/$id1?return=merge_center&to=$id2\">http://www.geni.com/merge/compare/$id1?return=merge_center&to=$id2</a>";
}
sub compareProfiles($$) {
	my $id1			= shift;
	my $id2			= shift;

	my $profiles_url = "http://www.geni.com/api/profiles/compare/$id1,$id2";
	my $filename = sprintf("$env{'datadir'}/%s-%s.json", $id1, $id2);
	getPage($filename, $profiles_url);
	printDebug($DBG_NONE, mergeURLHTML($id1, $id2) . "\n");

	if (jsonSanityCheck($filename) == 0) {
		unlink $filename;
		return 0;
	}

	my $fh = createReadFH($filename);
	my $json_data = <$fh>;
	my $json = new JSON;
	my $json_text = $json->allow_nonref->utf8->relaxed->decode($json_data);
	undef $fh;

	printDebug($DBG_JSON, sprintf ("Pretty JSON:\n%s", $json->pretty->encode($json_text))); 

	my $left_profile = new profile;
	my $right_profile= new profile;
	my $geni_profile = $left_profile;
	foreach my $json_profile (@{$json_text}) {

		# If the profile isn't on the big tree then don't merge it.
		# If the profile has a curator note it is probably a profile
		# subject to bad merges so don't merge it.
		if ($json_profile->{'focus'}->{'big_tree'} ne "true" ||
			$json_profile->{'focus'}->{'merge_note'} ne "") {
			unlink $filename;
			return 0;
		}

		# If there is more than one manager geni puts them in an
		# array, if not they just list it as a string.
		my @managers;
		if ($json_profile->{'focus'}->{'managers'} =~ /^(\d+)$/) {
			push @managers, $1;
		} else {
			@managers = @{$json_profile->{'focus'}->{'managers'}};
		}

		# Do not merge a profile managed by any of the blacklist_managers
		foreach my $profile_id (@managers) {
			if ($blacklist_managers{$profile_id}) {
				unlink $filename;
				return 0;
			}
		}

		my $profile_id = $json_profile->{'focus'}->{'id'};
		$geni_profile->name_first($json_profile->{'focus'}->{'first_name'});
		$geni_profile->name_middle($json_profile->{'focus'}->{'middle_name'});
		$geni_profile->name_last($json_profile->{'focus'}->{'last_name'});
		$geni_profile->name_maiden($json_profile->{'focus'}->{'maiden_name'});
		$geni_profile->suffix($json_profile->{'focus'}->{'suffix'});
		$geni_profile->gender($json_profile->{'focus'}->{'gender'});
		$geni_profile->living($json_profile->{'focus'}->{'living'});
		$geni_profile->death_date($json_profile->{'focus'}->{'death_date'});
		$geni_profile->death_year($json_profile->{'focus'}->{'death_year'});
		$geni_profile->birth_date($json_profile->{'focus'}->{'birth_date'});
		$geni_profile->birth_year($json_profile->{'focus'}->{'birth_year'});
		
		my @fathers_array;
		my @mothers_array;
		my @spouses_array;
		foreach my $i (keys %{$json_profile->{'nodes'}}) {
			next if $i !~ /union/;

			my $partner_type = "";
			# The "partners" will be parents
			if ($json_profile->{'nodes'}->{$i}->{'edges'}->{"profile-$profile_id"}->{'rel'} eq "child") {
				$partner_type = "parents";

			# The "partners" will be spouses 
			} elsif ($json_profile->{'nodes'}->{$i}->{'edges'}->{"profile-$profile_id"}->{'rel'} eq "partner") {
				$partner_type = "spouses";
			}

			# So far spouse and ex_spouse are the only two types I've seen
			my $union_type = $json_profile->{'nodes'}->{$i}->{'status'};
			next if ($union_type ne "spouse" && $union_type ne "ex_spouse");
			
			foreach my $j (keys %{$json_profile->{'nodes'}->{$i}->{'edges'}}) {
				# The profile that we are analyzing will be listed in the union,
				# just skip over it
				next if $j eq "profile-$profile_id";

				# We're ignoring children and siblings for now
				my $rel = $json_profile->{'nodes'}->{$i}->{'edges'}->{$j}->{'rel'};
				next if $rel ne "partner";

				my $gender = $json_profile->{'nodes'}->{$j}->{'gender'};
				my $name_first = $json_profile->{'nodes'}->{$j}->{'first_name'};
				my $name_middle = $json_profile->{'nodes'}->{$j}->{'middle_name'};
				my $name_last = $json_profile->{'nodes'}->{$j}->{'last_name'};
				my $name_maiden = $json_profile->{'nodes'}->{$j}->{'maiden_name'};
				my $name = cleanupName($name_first, $name_middle, $name_last, $name_maiden);

				if ($partner_type eq "parents") {
					if ($gender eq "male") {
						avoidDuplicatesPush($gender, \@fathers_array, $name);
					} elsif ($gender eq "female") {
						avoidDuplicatesPush($gender, \@mothers_array, $name);
					}
				} elsif ($partner_type eq "spouses") {
					avoidDuplicatesPush($gender, \@spouses_array, $name);
				}
			}
		}

		$geni_profile->fathers(join(":", @fathers_array));
		$geni_profile->mothers(join(":", @mothers_array));
		$geni_profile->spouses(join(":", @spouses_array));
		$geni_profile = $right_profile;
	}

	printDebug($DBG_MATCH_BASIC, "Fathers:\n");
	printDebug($DBG_MATCH_BASIC, sprintf("-left  : %s\n", $left_profile->fathers));
	printDebug($DBG_MATCH_BASIC, sprintf("-right : %s\n", $right_profile->fathers));

	printDebug($DBG_MATCH_BASIC, "Mothers:\n");
	printDebug($DBG_MATCH_BASIC, sprintf("-left  : %s\n", $left_profile->mothers));
	printDebug($DBG_MATCH_BASIC, sprintf("-right : %s\n", $right_profile->mothers));

	printDebug($DBG_MATCH_BASIC, "Spouses:\n");
	printDebug($DBG_MATCH_BASIC, sprintf("-left  : %s\n", $left_profile->spouses));
	printDebug($DBG_MATCH_BASIC, sprintf("-right : %s\n", $right_profile->spouses));

	# It would be nice to keep the files around for caching purposes but the
	# volume of files gets out of hand (30k+ in 24 hours) pretty quickly.
	unlink $filename;

	if (profileBasicsMatch($left_profile, $right_profile) == 0) {
		unlink $filename;
		return 0;
	}

	if (!comparePartners("male", "fathers", $left_profile->fathers, $right_profile->fathers)) {
		unlink $filename;
		return 0;
	}

	if (!comparePartners("female", "mothers", $left_profile->mothers, $right_profile->mothers)) {
		unlink $filename;
		return 0;
	}

	if (!comparePartners("female", "spouses", $left_profile->spouses, $right_profile->spouses)) {
		unlink $filename;
		return 0;
	}

	printDebug($DBG_MATCH_BASIC, "Profile parents/spouses DO match\n");
	return 1;
}

#
# Update the get_history file with the current timestamp
#
sub updateGetHistory() {
	(my $time_sec, my $time_usec) = Time::HiRes::gettimeofday();
	push @get_history, "$time_sec.$time_usec\n";
}

sub mergeProfiles($$$) {
	my $merge_url_api	= shift;
	my $id1			= shift;
	my $id2			= shift;

	(my $sec, my $min, my $hour, my $mday, my $mon, my $year, my $wday, my $yday, my $isdst) = localtime(time);
	my $merge_log_entry =
		sprintf("%s : %4d-%02d-%02d %02d:%02d:%02d : %s\n",
			$env{'username'}, $year+1900, $mon+1, $mday,
			$hour, $min, $sec, mergeURLHTML($id1, $id2));
	$env{'matches'}++;
	printDebug($DBG_PROGRESS, "MERGING: $id1 and $id2\n");
	printf $merge_log_fh "$merge_log_entry\n";

	if (!$env{'logged_in'}) {
		geniLogin();
	}
	$m->post($merge_url_api);
	updateGetHistory();
}

sub compareAllProfiles($$) {
	my $text		= shift;
	my $profiles_array_ptr	= shift;
	my @profiles_array = @$profiles_array_ptr;

	for (my $i = 0; $i <= $#profiles_array; $i++) {
		for (my $j = $i + 1; $j <= $#profiles_array; $j++) {
			print "$text\[$i] $profiles_array[$i] vs $text\[$j] $profiles_array[$j]\n";
		}
	}
}
sub analyzeTreeConflict($) {
	my $profile_id = shift;
	my $filename = "$env{'datadir'}/$profile_id\.json";
	print "analyzeTreeConflict called for $profile_id\n";

	getPage($filename, "http://www.geni.com/api/profiles/immediate_family/$profile_id");

	return 0 if jsonSanityCheck($filename) == 0;

	my $fh = createReadFH($filename);
	my $json_data = <$fh>;
	my $json = new JSON;
	my $json_text = $json->allow_nonref->utf8->relaxed->decode($json_data);
	undef $fh;

	if ($profile_id ne "6000000000252920365") {
		return;
	}

	$debug{"console_" . $DBG_JSON}	= 1;
	printDebug($DBG_JSON, sprintf ("Pretty JSON:\n%s", $json->pretty->encode($json_text)));

	my @fathers;
	my @mothers;
	my @spouses;
	my @sons;
	my @daughters;
	my @brothers;
	my @sisters;
	my $json_profile = $json_text;
	foreach my $i (keys %{$json_profile->{'nodes'}}) {
		next if $i !~ /union/;

		my $partner_type = "";
		# The "partners" will be parents
		if ($json_profile->{'nodes'}->{$i}->{'edges'}->{"profile-$profile_id"}->{'rel'} eq "child") {
			$partner_type = "parents";

		# The "partners" will be spouses 
		} elsif ($json_profile->{'nodes'}->{$i}->{'edges'}->{"profile-$profile_id"}->{'rel'} eq "partner") {
			$partner_type = "spouses";
		}

		foreach my $j (keys %{$json_profile->{'nodes'}->{$i}->{'edges'}}) {
			# The profile that we are analyzing will be listed in the union,
			# just skip over it
			next if $j eq "profile-$profile_id";

			my $rel = $json_profile->{'nodes'}->{$i}->{'edges'}->{$j}->{'rel'};
			my $gender = $json_profile->{'nodes'}->{$j}->{'gender'};
			my $id = $json_profile->{'nodes'}->{$j}->{'id'};
			if ($rel eq "partner") {
				if ($partner_type eq "parents") {
					if ($gender eq "male") {
						push @fathers, $id;
					} elsif ($gender eq "female") {
						push @mothers, $id;
					}
				} elsif ($partner_type eq "spouses") {
					push @spouses, $id;
				}

			} elsif ($rel eq "child") {

				if ($partner_type eq "parents") {
					if ($gender eq "male") {
						push @brothers, $id;
					} elsif ($gender eq "female") {
						push @sisters, $id;
					}
				} elsif ($partner_type eq "spouses") {
					if ($gender eq "male") {
						push @sons, $id;
					} elsif ($gender eq "female") {
						push @daughters, $id;
					}
				}
			} else {
				printDebug($DBG_NONE, "ERROR: unknown rel type '$rel'\n");
			}
		}
	}

	# dwalton - here now
	compareAllProfiles("Father", \@fathers);
	compareAllProfiles("Mother", \@mothers);
	compareAllProfiles("Spouse", \@spouses);
	compareAllProfiles("Sons", \@sons);
	compareAllProfiles("Daughters", \@daughters);
	compareAllProfiles("Brothers", \@brothers);
	compareAllProfiles("Sisters", \@sisters);
	exit(); # dwalton - remove
}

sub analyzePendingMerge($$) {
	my $id1			= shift;
	my $id2			= shift;

	if (compareProfiles($id1, $id2)) {
		mergeProfiles("http://www.geni.com/api/profiles/merge/$id1,$id2", $id1, $id2);
	}
}


sub rangeBeginEnd($$$) {
	my $range_begin = shift;
	my $range_end   = shift;
	my $type	= shift;

	my $filename = "";
	my $max_page = 1;

	if ($type eq "TREE_CONFLICTS") {
		printDebug($DBG_PROGRESS, "Determining the number of pages of tree conflicts...\n");
		$filename = "$env{'datadir'}/tree_conflicts_1.html";
		getPage($filename, "http://www.geni.com/list/merge_issues?issue_type=&page=1&order=merge_issue_date_modified&order_type=asc&group=&include_collaborators=true");
	} elsif ($type eq "PENDING_MERGES") {
		printDebug($DBG_PROGRESS, "Determining the number of pages of pending merges...\n");
		$filename = "$env{'datadir'}/merge_issues_1.html";
		getPage($filename, "http://www.geni.com/list/requested_merges?order=last_modified_at&direction=desc&include_collaborators=true&page=1");
	}

	# Figure out how many pages there are
	my $fh = createReadFH($filename);
	while(<$fh>) {
		if (($type eq "TREE_CONFLICTS" && /goToPage\('(\d+)'\)/) ||
		    ($type eq "PENDING_MERGES" && /\/list\/requested_merges\?page=(\d+)/)) {
			if ($1 > $max_page) {
				$max_page = $1;
			}
		}
	}
	undef $fh;

	if ($type eq "TREE_CONFLICTS") {
		printDebug($DBG_PROGRESS,
			sprintf("There are %d tree conflicts spread over %d pages\n",
				$max_page * 20, $max_page));
	} elsif ($type eq "PENDING_MERGES") {
		# The web page displays 20 per page, the json displays 50 so adjust max_page
		$max_page = int(($max_page * 20)/50);

		printDebug($DBG_PROGRESS,
			sprintf("There are %d pending merges spread over %d pages\n",
				$max_page * 50, $max_page));
	}

	if ($range_end > $max_page || !$range_end) {
		$range_end = $max_page;
	}

	if (!$range_begin) {
		$range_begin = 1;

		for (my $i = 1; $i <= $range_end; $i++) {
			if ($type eq "TREE_CONFLICTS" && -e "$env{'datadir'}/tree_conflicts_$i.html") {
				$range_begin = $i;
			} elsif ($type eq "PENDING_MERGES" && -e "$env{'datadir'}/merge_list_$i.json") {
				$range_begin = $i;
			}
		}

		printDebug($DBG_PROGRESS, "First Page: $range_begin\n");
	}

	return ($range_begin, $range_end);
}

sub createDebugFH($) {
	my $page_num = shift;

	undef $debug_fh;
	$env{'log_file'}	= "$env{'logdir'}/logfile_" . dateHourMinuteSecond() . "_page_$page_num\.html";
	$debug_fh		= createWriteFH("logfile", $env{'log_file'}, 0);
	$debug_fh->autoflush(1);
	print $debug_fh "<pre>";
}

sub printRunTime($$) {
	my $page_num		= shift;
	my $loop_start_time	= shift;

	my $loop_end_time = time();
	my $loop_run_time = $loop_end_time - $loop_start_time;
	printDebug($DBG_NONE,
		sprintf("Run time for page $page_num: %02d:%02d:%02d\n",
			int($loop_run_time/3600),
			int(($loop_run_time % 3600) / 60),
			int($loop_run_time % 60)));
	printDebug($DBG_PROGRESS, "$env{'matches'} matches out of $env{'profiles'} profiles so far\n");
}

#
# Loop through every page of Tree Conflicts....this can take days...
#
sub traverseTreeConflicts($$) {
	my $range_begin = shift;
	my $range_end   = shift;

	($range_begin, $range_end) = rangeBeginEnd($range_begin, $range_end, "TREE_CONFLICTS");

	for (my $i = $range_begin; $i <= $range_end; $i++) {
		createDebugFH($i);

		my $loop_start_time = time();
		my $page_profile_count = 0;
		my $filename = "$env{'datadir'}/tree_conflicts_$i.html";
		printDebug($DBG_PROGRESS, "Downloading Tree Conflicts list for page $i...\n");
		getPage($filename, "http://www.geni.com/list/merge_issues?issue_type=&page=$i&order=merge_issue_date_modified&order_type=asc&group=&include_collaborators=true");

		# Screen scrape this until geni is able to give us an API for our tree conflicts list
		my @profiles_with_tree_conflicts;
		my $fh = createReadFH($filename);
		while(<$fh>) {
# <a href="/people/Martha-BECK/6000000000252927371" class="linkTertiary" rel="friend">Martha Ann BECK</a> <span id="shared_icon_6000000000252927371" style="display:none;"><img alt="Icn_world" src="http://assets0.geni.com/images/icn_world.gif?1258076471" style="vertical-align:-3px;" title="Public Profile" /></span>
# <a href="/people/Catherine-NUECHTER/6000000000252921711" class="linkTertiary" rel="friend">Catherine Elizabeth NUECHTER</a> <span id="shared_icon_6000000000252921711" style="display:none;"><img alt="Icn_world" src="http://assets0.geni.com/images/icn_world.gif?1258076471" style="vertical-align:-3px;" title="Public Profile" /></span>
			if (/a href=\"\/people\/.*?\/(\d+)\" class.*Public Profile/) {
				push @profiles_with_tree_conflicts, $1;
			}
		}
		undef $fh;

		foreach my $profile (@profiles_with_tree_conflicts) {
			analyzeTreeConflict($profile);
		}
		printRunTime($i, $loop_start_time);
		exit(); # dwalton - remove
	} # End of range_begin/range_end for loop

	printDebug($DBG_PROGRESS, "$env{'matches'} matches out of $env{'profiles'} profiles from page $range_begin to $range_end\n");
}

#
# Loop through every page of pending merges and analyze all
# merges listed on each page. This can take days....
#
sub traversePendingMergePages($$) {
	my $range_begin	= shift;
	my $range_end	= shift;

	($range_begin, $range_end) = rangeBeginEnd($range_begin, $range_end, "PENDING_MERGES");

	for (my $i = $range_begin; $i <= $range_end; $i++) {
		createDebugFH($i);

		my $loop_start_time = time();
		my $page_profile_count = 0;
		my $filename = "$env{'datadir'}/merge_list_$i.json";
		printDebug($DBG_PROGRESS, "Downloading pending merges list for page $i...\n");
		getPage($filename, "http://www.geni.com/api/profiles/merges?collaborators=true&order=last_modified_at&direction=asc&page=$i");

		if (jsonSanityCheck($filename) == 0) {
			# Since the file was hosed, delete it
			unlink $filename;
			next;
		}

		my $fh = createReadFH($filename);
		my $json_data = <$fh>;
		my $json = new JSON;
		my $json_text = $json->allow_nonref->utf8->relaxed->decode($json_data);
		undef $fh;

		foreach my $json_profile_pair (@{$json_text}) {
			$env{'profiles'}++;
			$page_profile_count++;
			printDebug($DBG_PROGRESS, "Page $i/$range_end Profile $page_profile_count: Overall Profile $env{'profiles'}\n");

			if ($json_profile_pair->{'profiles'} =~ /\/(\d+),(\d+)$/) {
				analyzePendingMerge($1, $2);
			}
			printDebug($DBG_NONE, "\n");
		} # End of json_profile_pair for loop

		printRunTime($i, $loop_start_time);
	} # End of range_begin/range_end for loop

	printDebug($DBG_PROGRESS, "$env{'matches'} matches out of $env{'profiles'} profiles from page $range_begin to $range_end\n");
}

sub runTestCases() {
	my @name_tests;
	push @name_tests, "Robert James Robert Smith:robert james smith";
	push @name_tests, "Robert Robert Smith:robert smith";
	push @name_tests, "tiberius claudius nero claudius tiberius claudius nero:tiberius claudius nero";
	my $index = 1;
	foreach my $test (@name_tests) {
		(my $test_name, my $expected_result) = split(/:/, $test);
		my $result = cleanupName($test_name, "", "", "");
		printDebug($DBG_PROGRESS,
			sprintf("cleanupName Test #%d: %s, Test Name '%s', Result '%s'\n",
				$index,
				($result eq $expected_result) ? "PASSED" : "FAILED",
				$test_name,
				$result));
		$index++;
	}
	print "\n";
	
	my @date_tests;
	push @date_tests, "1/1/1900:Jan 1900:1";
	push @date_tests, "1/1/1900:1900:1";
	push @date_tests, "c. 1901:1900:1";
	push @date_tests, "c. 1905:1900:0";
	push @date_tests, "1/1/1900:1901:0";

	# todo: fix this scenario
	# For 6000000000234140489,6000000000234293794
	#  http://www.geni.com/merge/compare/6000000000234140489?return=merge_center&to=6000000000234293794
	# Husband is:
	#  johannes stalknecht
	# Wives are:
	#  anna margaretha stalknecht
	#  anna margaretha pretorius
	#
	# We need to pass the husband's last name when comparing two wives

	my @name_tests;
	push @name_tests, "female:Jane Smith ():Jane Doe ():0";
	push @name_tests, "female:Jane Smith (Doe):Jane Doe ():1";
	push @name_tests, "female:Jane Doe (Smith):Jane Smith (Doe):0";
	push @name_tests, "male:John Doe (foo):John Doe (bar):1";
	push @name_tests, "male:John Smith (Doe):John Doe ():0";
	push @name_tests, "female:margaret neville (pole):margaret ():1";
	$index = 1;
	foreach my $test (@name_tests) {
		(my $gender, my $left_name, my $right_name, my $expected_result) = split(/:/, $test);
		my $result = compareNames($gender, $left_name, $right_name);
		printDebug($DBG_PROGRESS,
			sprintf("compareNames Test #%d: %s, %s, Left Name '%s', Right Name '%s', Result '%s'\n",
				$index,
				($result eq $expected_result) ? "PASSED" : "FAILED",
				$gender,
				$left_name,
				$right_name,
				$result ? "Names MATCHED" : "NAMES DID NOT MATCH"));
		$index++;
	}
	print "\n";


	$index = 1;
	foreach my $test (@date_tests) {
		(my $date1, my $date2, my $expected_result) = split(/:/, $test);
		my $result = dateMatches($date1, $date2);
		printDebug($DBG_PROGRESS,
			sprintf("dateMatches Test #%d: %s, Date1 '%s', Date2 '%s', Result '%s'\n",
				$index,
				($result eq $expected_result) ? "PASSED" : "FAILED",
				$date1,
				$date2,
				$result ? "DATES MATCHED" : "DATES DID NOT MATCH"));
		$index++;
	}
	print "\n";

	my @phonetics_tests;
#	push @phonetics_tests, "williams:willliams";
#	push @phonetics_tests, "walters:walton";
#	push @phonetics_tests, "byron:bryon";
#	push @phonetics_tests, "booth:boothe";
#	push @phonetics_tests, "margaret:margery";
#	push @phonetics_tests, "hepsibah:hepzibah";
	$index = 1;
	foreach my $test (@phonetics_tests) {
		(my $left_name, my $right_name) = split(/:/, $test);
		my $doubleM_result = doubleMetaphoneCompare($left_name, $right_name);
		printDebug($DBG_PROGRESS,
			sprintf("Phonetics Test #%d: Left Name '%s', Right Name '%s',  Double Metaphone %s\n",
				$index,
				$left_name,
				$right_name,
				$doubleM_result ? "MATCHED" : "DID NOT MATCH"));
		$index++;
	}
	print "\n";

#	my $read_name_list_fh = createReadFH($env{'name_list_file'});
#	while(<$read_name_list_fh>) {
#		chomp();
#		(my $left_name, my $right_name) = split(/:/, $_);
#		if (doubleMetaphoneCompare($left_name, $right_name)) {
#			printDebug($DBG_PROGRESS,
#				sprintf("Phonetics Test: Left Name '%s', Right Name '%s',  Double Metaphone MATCHED\n",
#					$left_name, $right_name));
#		}
#	}
#	undef $read_name_list_fh;
}

sub main() {
	$env{'username'}	= "";
	$env{'password'}	= "";
	my $range_begin		= 0;
	my $range_end		= 0;
	my $left_id		= 0;
	my $right_id		= 0;

	#
	# Parse all command line arguements
	#
	for (my $i = 0; $i <= $#ARGV; $i++) {
		if ($ARGV[$i] eq "-u" || $ARGV[$i] eq "-username") {
			$env{'username'} = $ARGV[++$i];

		} elsif ($ARGV[$i] eq "-p" || $ARGV[$i] eq "-password") {
			$env{'password'} = $ARGV[++$i];

		} elsif ($ARGV[$i] eq "-c" || $ARGV[$i] eq "-circa") {
			$env{'circa_range'} = $ARGV[++$i];

		} elsif ($ARGV[$i] eq "-pm" || $ARGV[$i] eq "-pendingmerge") {
			$left_id = $ARGV[++$i];
			$right_id = $ARGV[++$i];
			$debug{"file_" . $DBG_JSON} = 1;
			$env{'action'} = "pendingmerge";

		} elsif ($ARGV[$i] eq "-t" || $ARGV[$i] eq "-test") {
			$env{'action'} = "test";

		} elsif ($ARGV[$i] eq "-treeconflicts") {
			$env{'action'} = "traverse_tree_conflicts";

		} elsif ($ARGV[$i] eq "-tc" || $ARGV[$i] eq "-treeconflict") {
			$left_id = $ARGV[++$i];
			$env{'action'} = "treeconflict";

		} elsif ($ARGV[$i] eq "-rb") {
			$range_begin = $ARGV[++$i];

		} elsif ($ARGV[$i] eq "-re") {
			$range_end = $ARGV[++$i];

		} elsif ($ARGV[$i] eq "-api_get_timeframe") {
			$env{'get_timeframe'} = $ARGV[++$i];

		} elsif ($ARGV[$i] eq "-api_get_limit") {
			$env{'get_limit'} = $ARGV[++$i];

		} elsif ($ARGV[$i] eq "-h" || $ARGV[$i] eq "-help") {
			printHelp();

		} else { 
			printDebug($DBG_NONE, "ERROR: '$ARGV[$i]' is not a supported arguement\n");
			printHelp();
		}
	}

	print $merge_log_fh "<pre>";
	print $debug_fh "<pre>";

	if ($env{'action'} eq "traverse_pending_merges") {
		traversePendingMergePages($range_begin, $range_end);

	} elsif ($env{'action'} eq "pendingmerge") {
		if (!$left_id || !$right_id) {
			print STDERR "\nERROR: You must specify two profile IDs, you only specified one\n";
			exit();
		}

		analyzePendingMerge($left_id, $right_id);

	} elsif ($env{'action'} eq "traverse_tree_conflicts") {
		traverseTreeConflicts($range_begin, $range_end);

	} elsif ($env{'action'} eq "traverseconflict") {
		if (!$left_id || $left_id !~ /^\d+$/) {
			print STDERR "\nERROR: You must specify a profile ID, you entered '$left_id'\n";
			exit();
		}

		analyzeTreeConflict($left_id);

	} elsif ($env{'action'} eq "test") {
		runTestCases();
	}

	geniLogout();
	my $end_time = time();
	my $run_time = $end_time - $env{'start_time'};
	printDebug($DBG_NONE,
		sprintf("Total running time: %02d:%02d:%02d\n",
			int($run_time/3600),
			int(($run_time % 3600) / 60),
			int($run_time % 60)));

	print $merge_log_fh "</pre>";
	undef $merge_log_fh;
	undef $name_list_fh;
	print $debug_fh "</pre>";
	undef $debug_fh;
}

__END__
46,805,758 big tree profiles on 10/29/2010

DONE
- better debugs
- File IO module
- functions from work script
- measure how many req we did in the last 10 seconds

TODO
- write wiki
