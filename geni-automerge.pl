#!/usr/bin/perl

use strict;
use WWW::Mechanize;
use HTTP::Cookies;
use Class::Struct;
use Time::HiRes;
use JSON;
# http://search.cpan.org/~maurice/Text-DoubleMetaphone-0.07/DoubleMetaphone.pm
use Text::DoubleMetaphone qw( double_metaphone );
# Since we use HTTPS, must have support for it. This makes it easy to understand
# what's wrong if it's not installed.
use IO::Socket::SSL;
use HTTP::Response;

binmode STDOUT, ":utf8";
binmode STDERR, ":utf8";

# globals and constants
my (%env, %debug, %blacklist_managers, @get_history, %new_tree_conflicts);
my (%cache_private_profiles, %cache_merge_request, %cache_merge_fail, %cache_no_match, %cache_name_mismatch);
my $m = WWW::Mechanize->new(autocheck => 0);
my $DBG_NONE			= "DBG_NONE"; # Normal output
my $DBG_PROGRESS		= "DBG_PROGRESS";
my $DBG_URLS			= "DBG_URLS";
my $DBG_IO			= "DBG_IO";
my $DBG_NAMES			= "DBG_NAMES";
my $DBG_JSON			= "DBG_JSON";
my $DBG_MATCH_DATE		= "DBG_MATCH_DATE";
my $DBG_MATCH_BASIC		= "DBG_MATCH_BASIC";
my $DBG_TIME			= "DBG_TIME";

our $CALLED_BY_TEST_SCRIPT;

if (!$CALLED_BY_TEST_SCRIPT) {
    init();
    main();
}

sub init(){
	# configuration
	$env{'circa_range'}		= 5;
	$env{'get_timeframe'}		= 10;
	$env{'get_limit'}		= 39; # The limit is 40 so use 39 just to be safe
	$env{'action'}			= "pending_merges";

	# environment
	$env{'start_time'}		= time();
	$env{'logged_in'}		= 0;
	$env{'matches'} 		= 0;
	$env{'profiles'}		= 0;
	$env{'merge_little_trees'}	= 0;
	$env{'all_of_geni'}		= 0;
	$env{'loop'}			= 0;
	$env{'delete_files'}		= 1;

	$debug{"file_" . $DBG_NONE}		= 0;
	$debug{"file_" . $DBG_PROGRESS}		= 0;
	$debug{"file_" . $DBG_IO}		= 0;
	$debug{"file_" . $DBG_URLS}		= 0;
	$debug{"file_" . $DBG_NAMES}		= 0;
	$debug{"file_" . $DBG_JSON}		= 0;
	$debug{"file_" . $DBG_MATCH_BASIC}	= 0;
	$debug{"file_" . $DBG_MATCH_DATE}	= 0;
	$debug{"file_" . $DBG_TIME}		= 0;
	$debug{"console_" . $DBG_NONE}		= 0;
	$debug{"console_" . $DBG_PROGRESS}	= 1;
	$debug{"console_" . $DBG_IO}		= 0;
	$debug{"console_" . $DBG_URLS}		= 0;
	$debug{"console_" . $DBG_NAMES}		= 0;
	$debug{"console_" . $DBG_JSON}		= 0;
	$debug{"console_" . $DBG_MATCH_BASIC}	= 0;
	$debug{"console_" . $DBG_MATCH_DATE}	= 0;
	$debug{"console_" . $DBG_TIME}		= 0;

	struct (profile => {
		first_name		=> '$',
		middle_name		=> '$',
		last_name		=> '$',
		maiden_name		=> '$',
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
		public			=> '$',
		fathers			=> '$',
		mothers			=> '$',
		spouses			=> '$'
	});

	# It is a long story but for now don't merge profiles managed by the following:
	# http://www.geni.com/people/Wendy-Hynes/6000000003753338015#/tab/overview
	# http://www.geni.com/people/Alan-Sciascia/6000000009948172621#/tab/overview
	$blacklist_managers{"6000000003753338015"} = 1;
	$blacklist_managers{"6000000009948172621"} = 1;
	$blacklist_managers{"6000000007167930983"} = 1;
	$blacklist_managers{"6000000007190994696"} = 1;
}


#
# Print the syntax for running the script including all command line options
#
sub printHelp() {
	print STDERR "\ngeni-automerge.pl\n\n";
	print STDERR "Required:\n";
	print STDERR "-u \"user\@email.com\"\n";
	print STDERR "-p \"password\"\n";
	print STDERR "\n";
	print STDERR "One of these is required:\n";
	print STDERR "-pms   : Pending Merges - Analyze your entire list\n";
	print STDERR "-pm X Y: Pending Merges - Analyze profile IDs X vs. Y\n";
#	print STDERR "-pmfg X: Pending Merges - Analyze for the family-group of profile ID X\n";
	print STDERR "-tcs   : Tree Conflicts - Analyze your entire list\n";
	print STDERR "-tc X  : Tree Conflicts - Analyze profile ID X\n";
	print STDERR "-tcr X : Tree Conflicts - Analyze recursively for profile ID X\n";
#	print STDERR "-tms   : Tree Matches   - Analyze your entire list\n";
#	print STDERR "-tm X  : Tree Matches   - Analyze profile ID X\n";
#	print STDERR "-dcs   : Data Conflicts - Analyze your entire list\n";
#	print STDERR "-dc X  : Data Conflicts - Analyze profile ID X\n";
	print STDERR "-stack X \"A,B,C\": Stack profiles A, B, and C onto profile X\n";
	print STDERR "\n";
	print STDERR "Options for analyzing a list:\n";
	print STDERR "-all : Include 'all of geni' pending merges, tree conflicts, etc\n";
	print STDERR "-rb X: X is the starting page\n";
	print STDERR "-re X: X is the ending page\n";
	print STDERR "-loop: Start over at the first page when finished\n";
	print STDERR "\n";
	print STDERR "Misc Options:\n";
	print STDERR "-mlt : Enables merging a little tree into the big tree\n";
	print STDERR "-x   : Delete temp files in logs and script_data directories\n";
	print STDERR "-h   : print this menu\n\n";
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
	if ($debug{"file_" . $debug_flag}) {
		write_file($env{'log_file'}, $msg, 1);
	}
}

#
# Print the die_message and logout of geni
#
sub gracefulExit($) {
	my $msg = shift;
	
	# If the logfile doesn't exist don't try to write to it
	if (-e $env{'log_file'}) {
		printDebug($DBG_PROGRESS, $msg);
	} else {
		print STDERR $msg;
	}
	geniLogout();
	exit();
}

sub write_file($$$){
	my $file = shift;
	my $data = shift;
	my $append = (shift) ? ">>" : ">"; # use 1 to append. 0 overwrites the entire file
	if ($file eq "") {
	    return;
	}
	open(OUT,"$append$file") || gracefulExit("\n\nERROR: write_file could not open '$file'\n\n");
	binmode OUT, ":utf8";
	while(!(flock OUT, 2)){}
	print OUT $data;
	flock OUT, 8; # unlock
	close OUT;
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
	my $result = new HTTP::Response;
	$result = $m->post("https://www.geni.com/login/in?username=$env{'username'}&password=$env{'password'}");
	updateGetHistory("geniLogin");

	if (!$result->is_success || $result->decoded_content =~ /Welcome to Geni/i) {
		printDebug($DBG_PROGRESS, "ERROR: Login FAILED for www.geni.com!!\n");
		exit();
	}

	$env{'logged_in'} = 1;
	printDebug($DBG_PROGRESS, "Login PASSED for www.geni.com!!\n");
}

#
# Logout of geni
#
sub geniLogout() {
	return if !$env{'logged_in'};
	printDebug($DBG_PROGRESS, "\nLogging out of www.geni.com\n");
	$m->get("http://www.geni.com/logout?ref=ph");
}

# Return TRUE if the json file queried a private profile
sub jsonIsPrivate($) {
	my $filename = shift;

	open (INF,$filename);
	my $json_data = <INF>;
	close INF;

	# Some profiles are private and we cannot access them
	if ($json_data =~ /Access denied/i || $json_data =~ /SecurityError/i) {
		printDebug($DBG_NONE, "NOTICE: Private profile in '$filename'\n");
		return 1;
	}

	return 0;
}
sub jsonSanityCheck($) {
	my $filename = shift;

	open (INF,$filename);
	my $json_data = <INF>;
	close INF;

	# We "should" never hit this
	if ($json_data =~ /Rate limit exceeded/i) {
		printDebug($DBG_PROGRESS, "ERROR: 'Rate limit exceeded' for '$filename'\n");
		sleep(10);
		return 0;
	}

	# I've only seen this once.  Not sure what the trigger is or if the
	# sleep will fix it.
	if ($json_data =~ /500 read timeout/i) {
		printDebug($DBG_PROGRESS, "NOTICE: 500 read timeout in '$filename'\n");
		sleep(10);
		return 0;
	}

	if ($json_data =~ /apiexception/i) {
		printDebug($DBG_PROGRESS, "NOTICE: API Exception in '$filename'\n");
		sleep(10);
		return 0;
	}

	if ($json_data =~ /DOCTYPE HTML PUBLIC/) {
		printDebug($DBG_PROGRESS, "ERROR: 'DOCTYPE HTML PUBLIC' for '$filename'\n");
		return 0;
	}

	if ($json_data =~/tatus read failed/) {
		printDebug($DBG_PROGRESS, "ERROR: 'Status read failed' for '$filename'\n");
		return 0;
	}

	if ($json_data =~/an't connect to www/) {
		printDebug($DBG_PROGRESS, "ERROR: 'Can't connect to www' for '$filename'\n");
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
# Always pass the most recent time as time_A.  The time strings look like:
# EpochSeconds.Microseconds
# 1288721911.894155
# 1288721917.83155
# 1288721923.200155
# 1288721928.390155
#
sub timestampDelta($$) {
	my $time_A = shift;
	my $time_B = shift;

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

	return $delta;
}

#
# Return TRUE if $time_A and $time_B are within $threshold of each other.
# $threshold should be in seconds.  Always pass the most recent time as time_A. 
#
sub timesInRange($$$) {
	my $time_A = shift;
	my $time_B = shift;
	my $threshold = shift;

	my $delta = timestampDelta($time_A, $time_B);
	return 1 if $delta <= ($threshold * 1000000);
	return 0;
}

sub roundup($) {
	my $n = shift;
	return(($n == int($n)) ? $n : int($n + 1))
}

sub sleepIfNeeded() {
	(my $time_sec, my $time_usec) = Time::HiRes::gettimeofday();
	my $time_current = "$time_sec.$time_usec";
	my @new_get_history;
	my $gets_in_api_timeframe = 0;
	foreach my $timestamp (@get_history) {
		chomp($timestamp);
		if (timesInRange($time_current, $timestamp, $env{'get_timeframe'})) {
			$gets_in_api_timeframe++;
			push @new_get_history, $timestamp;
		}
	}
	@get_history = @new_get_history;

	if ($gets_in_api_timeframe >= $env{'get_limit'}) {
		# index is the timestamp entry that needs to expire before we can do another get
		my $index = $gets_in_api_timeframe - $env{'get_limit'};
		my $new_to_old_delta = int(timestampDelta($time_current, $get_history[$index])/1000000);
		my $sleep_length = $env{'get_timeframe'} - $new_to_old_delta;

		if (!$sleep_length) {
			printDebug($DBG_TIME, "ERROR: sleep_length was 0.  Using $env{'get_timeframe'} instead\n");
			$sleep_length = $env{'get_timeframe'};
		}
		printDebug($DBG_TIME,
			sprintf("%d gets() in the past %d seconds....sleeping for %d second%s\n",
				$gets_in_api_timeframe, $env{'get_timeframe'}, $sleep_length, $sleep_length > 1 ? "s" : ""));
		sleep($sleep_length);
	}
}

#
# Return TRUE if number1 or number2 were marked with circa and fall within +/- circa_range of each other.
# Else only return TRUE if they match exactly
#
sub numbersInRange($$$$) {
	my $number1 = shift;
	my $number2 = shift;
	my $circa = shift;
	my $circa_range = shift;

	return 1 if ((!$number1 && $number2) || ($number1 && !$number2));
	return (abs(($number1) - ($number2)) <= $circa_range ? 1 : 0) if $circa;
	return ($number1 == $number2); 
}

sub monthDayYear($) {
	my $date = shift;

	my $date_month = 0;
	my $date_day = 0;
	my $date_year = 0;
	my %months = ('0','0','','0','1','jan','2','feb','3','mar',
		'4','apr','5','may','6','jun','7','jul',
		'8','aug','9','sep','10','oct',
		'11','nov','12','dec');

	# 7/1/1700
	if ($date =~ /(\d+)\/(\d+)\/(\d+)/) {
		$date_month	= $1;
		$date_day	= $2;
		$date_year	= $3;

	# July 1700
	} elsif ($date =~ /(\w+) (\d+)/) {
		$date_month = $1;
		$date_year  = $2;
		$date_month = $months{$date_month};

	# 1700
	} elsif ($date =~ /(\d+)/) {
		$date_year  = $1;

	# July
	} elsif ($date =~ /(\w+)/) {
		$date_month = $1;
		$date_month = $months{$date_month};
	}

	return ($date_month, $date_day, $date_year);
}

#
# Return true if the dates match or if one is a more specific date within the same year
#
sub dateMatches($$) {
	my $date1 = shift;
	my $date2 = shift;
	my $debug_string = "date1($date1) vs. date2($date2)\n";

	if ($date1 eq $date2) {
		# To reduce debug output, don't print the debug when both are "" 
		printDebug($DBG_MATCH_DATE, "MATCH: $debug_string") if $date1 ne "";
		return 1;
	}

	# If one date is blank and the other is not then we consider one to be more specific than the other
	if (($date1 ne "" && $date2 eq "") ||
		 ($date1 eq "" && $date2 ne "")) {
		printDebug($DBG_MATCH_DATE, "MATCH: $debug_string");
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

	# If the year is pre 1800 then assume circa.  If you don't do this there are too many dates that
	# are off by a year or two that never match
	if (($date1_year && $date1_year <= 1800) ||
		($date2_year && $date2_year <= 1800)) {
		$circa = 1;
	}

	my $day_circa_range = 31;
	my $day_circa = (($date1_year && $date1_year <= 1900) || ($date2_year && $date2_year <= 1900));

#	printDebug($DBG_MATCH_DATE, "\n date1_month: $date1_month\n");
#	printDebug($DBG_MATCH_DATE, " date1_day  : $date1_day\n");
#	printDebug($DBG_MATCH_DATE, " date1_year : $date1_year\n");
#	printDebug($DBG_MATCH_DATE, " date2_month: $date2_month\n");
#	printDebug($DBG_MATCH_DATE, " date2_day  : $date2_day\n");
#	printDebug($DBG_MATCH_DATE, " date2_year : $date2_year\n");
#	printDebug($DBG_MATCH_DATE, " circa      : $circa\n\n");

	if (numbersInRange($date1_year, $date2_year, $circa, $env{'circa_range'})) {
		if (($date1_month && $date2_month && $date1_month == $date2_month) || 
			(!$date1_month || !$date2_month)) {
			if (numbersInRange($date1_day, $date2_day, $day_circa, $day_circa_range)) { 
				printDebug($DBG_MATCH_DATE, "MATCH: $debug_string");
				return 1;
			}
		}
	}

	printDebug($DBG_MATCH_DATE, "NO_MATCH: $debug_string");
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

	# Remove everything in //s
	while ($name =~ /\/.*?\//) {
		$name = $` . " " . $';
	}

	# Treat the I in "Edgar I of England" differently from "Robert I. Smith"
	# We want to remember the I/V/X that are abbreviations but remove the others.
	$name =~ s/I\./ INITIAL_I /g;
	$name =~ s/V\./ INITIAL_V /g;
	$name =~ s/X\./ INITIAL_X /g;

	# Remove punctuation
	$name =~ s/ d\'/ /g;
	$name =~ s/\&/ /g;
	$name =~ s/\+/ /g;
	$name =~ s/\./ /g;
	$name =~ s/\?/ /g;
	$name =~ s/\*/ /g;
	$name =~ s/\~/ /g;
	$name =~ s/\:/ /g;
	$name =~ s/\,/ /g;
	$name =~ s/\'/ /g;
	$name =~ s/\"/ /g;
	$name =~ s/\^/ /g;
	$name =~ s/\// /g;
	$name =~ s/\\/ /g;
	$name =~ s/\[/ /g;
	$name =~ s/\]/ /g;
	$name =~ s/\(/ /g; # Note: If there were a ( and ) they would have already been removed
	$name =~ s/\)/ /g; # but it is possible to have one or the other

	# Remove 1st, 2nd, 3rd, 1900, 1750, etc
	if ($name =~ /\b\d+(st|nd|rd|th)*\b/) {
		$name = $` . " " . $';
	}

	my @strings_to_remove = (# Do the multi-word phrases first
				"private first class", "pfc",
				"chief justice",
				"chief warrant officer", "cwo",
				"rear admiral",
				"vice admiral",
				"lance corporal",
				"warrant officer",
				"petty officer",
				"no name",
				"marine corps", "air force",

				# Now do all of the single word phrases
				"army", "navy", "usaf", "usmc",
				"di", "de", "of", "av", "la", "le", "du", "-", "the",
				"daughter", "dau", "wife", "mr", "mrs", "miss", "dr", "son",
				"duchess", "lord", "duke", "earl", "prince", "princess", "king", "queen", "baron",
				"airman", "basic", "seaman", "fleet", "force", "ensign",
				"admiral",
				"captain", "capt", "cpt",
				"chief",
				"class",
				"colonel", "col",
				"commander",
				"command",
				"corporal", "cpl",
				"count", "countess", "ct", "cnt",
				"csa", 
				"general", "gen", "brigadier",
				"governor", "gov",
				"gunnery",
				"honorable", "hon",
				"i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x", "xi", "xii", "xiii",
				"first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
				"junior", "jr",
				"knight",
				"lieutenant", "lieut", "lt",
				"major", "maj", "mjr",
				"master",
				"mayor",
				"officer",
				"president", "pres",
				"reverend", "rev",
				"sergeant", "sgt",
				"senior", "sr",
				"sheriff",
				"sir",
				"specialist",
				"staff",
				"widow",
				"unknown", "nn", "<unknown>", "unk", "unkf", "unkm");

	# Remove double (or more) whitespaces
	while ($name =~ /\s\s/) {
		$name = $` . " " . $';
	}

	# Remove leading and trailing whitespaces
	$name =~ s/^\s+//;
	$name =~ s/\s+$//;

	foreach my $rm_string (@strings_to_remove) {
		while ($name =~ /^$rm_string /i) {
			$name = $';
		}
		while ($name =~ / $rm_string$/i) {
			$name = $`;
		}
		while ($name =~ / $rm_string /i) {
			$name = $` . " " . $';
		}
		if ($name eq $rm_string) {
			$name = "";
		}
	}

	$name =~ s/ INITIAL_I / I /g;
	$name =~ s/ INITIAL_V / V /g;
	$name =~ s/ INITIAL_X / X /g;
	# If it says "jim or james" then string it together to look like one word.
	# We'll break it apart later and compare each of the names.
	$name =~ s/ or /_or_/g;

	# Remove double (or more) whitespaces
	while ($name =~ /\s\s/) {
		$name = $` . " " . $';
	}

	# Remove leading and trailing whitespaces
	$name =~ s/^\s+//;
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

sub nameToFirstMiddleLastMaiden($) {
	my $name = shift;
	my $first_name	= "";
	my $middle_name	= "";
	my $last_name	= "";
	my $maiden_name	= "";

	if ($name =~ / \((.*)\)$/) {
		$maiden_name = $1;
		$name = $`;
	}

	if ($name =~ /^(.*?)\s(.*)\s(.*?)$/) {
		$first_name = $1;
		$middle_name = $2;
		$last_name = $3;
	} elsif ($name =~ /^(.*?)\s(.*?)$/) {
		$first_name = $1;
		$last_name = $2;
	} elsif ($name =~ /^(.*?)$/) {
		$first_name = $1;
	# This should not happen
	} else {
		$first_name = $name;
	}

	return ($first_name, $middle_name, $last_name, $maiden_name);
}

sub getMaleLastNames($) {
	my $profile_id = shift;

	my $filename = "$env{'datadir'}/$profile_id\.json";

	my $url = "https://www.geni.com/api/profile-$profile_id/immediate-family?only_ids=true";
	my $json_profile = getJSON($filename, $url, $profile_id, 0);
	return ("","") if (!$json_profile);

	my @fathers, my @mothers, my @spouses, my @sons, my @daughters, my @brothers, my @sisters;
	jsonToFamilyArrays($json_profile, $profile_id, \@fathers, \@mothers, \@spouses, \@sons, \@daughters, \@brothers, \@sisters);

	# If the last names of all fathers are the same then return that name.
	# If there is any disagreement return "".
	my $father_last_name = "";
	foreach my $father_string (@fathers) {
		(my $id, my $name, my $gender) = split(/:/, $father_string);
		(my $first, my $middle, my $last, my $maiden) = nameToFirstMiddleLastMaiden($name);
		if ($father_last_name ne "" && $father_last_name ne $last) {
			$father_last_name = "";
			last;
		}
		$father_last_name = $last;
	}

	# If the last names of all husbands are the same then return that name.
	# If there is any disagreement return "".
	my $husband_last_name = "";
	foreach my $husband_string (@spouses) {
		(my $id, my $name, my $gender) = split(/:/, $husband_string);
		(my $first, my $middle, my $last, my $maiden) = nameToFirstMiddleLastMaiden($name);
		if ($husband_last_name ne "" && $husband_last_name ne $last) {
			$husband_last_name = "";
			last;
		}
		$husband_last_name = $last;
	}
	
	unlink $filename if $env{'delete_files'};
	return ($father_last_name, $husband_last_name);
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

	# printDebug($DBG_NAMES, "cleanupName: Initial Name: first '$first', middle '$middle', last '$last', maiden '$maiden'\n");
	$name = $first if $first;
	$name .= " $middle" if $middle;
	$name .= " $last" if $last;
	printDebug($DBG_NAMES, sprintf("cleanupName  pre-clean: %s%s\n", $name, $maiden ? " ($maiden)" : ""));

	$name = cleanupNameGuts($name);
	$maiden = cleanupNameGuts($maiden);
	$name .= " ($maiden)" if $maiden;

	printDebug($DBG_NAMES, "cleanupName post-clean: $name\n\n");
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
		# DO NOTE USE \w here, it matches on hebrew characters
		if ($char !~ /a-ZA-Z0-9/) {
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
	if ($left_name =~ / / || $right_name =~ / /) {
		return 0;
	}

	# This should never happen but just to be safe
	if ($left_name eq "" || $right_name eq "") {
		return 0;
	}

	# If one of the names is just an initial then bail out
	if ($left_name =~ /^.$/ || $right_name =~ /^.$/) {
		return 0;
	}

	# Non-english names give too many false positives so if the name is full
	# of funky characters then don't even bother running metaphone.
	if (oddCharCount($left_name) > 1 || oddCharCount($right_name) > 1) {
		return 0;
	}

	(my $left_code1, my $left_code2) = double_metaphone($left_name);
	(my $right_code1, my $right_code2) = double_metaphone($right_name);

	return (($left_code1 eq $right_code1) || ($left_code1 eq $right_code2) || ($left_code2 eq $right_code1) ||
		($left_code2 eq $right_code2 && $left_code2));
}

sub recordMergeComplete($$$$) {
	my $id1			= shift;
	my $id2			= shift;
	my $desc		= shift;
	my $winner		= shift;

	my $id1_url = "<a href=\"http://www.geni.com/profile-$id1\">$id1</a>";
	my $id2_url = "<a href=\"http://www.geni.com/profile-$id2\">$id2</a>";
	(my $sec, my $min, my $hour, my $mday, my $mon, my $year, my $wday, my $yday, my $isdst) = localtime(time);

	write_file($env{'merge_log_file'},
			sprintf("%4d-%02d-%02d %02d:%02d:%02d :: %s :: %s :: Merged %s with %s\n",
 				$year+1900, $mon+1, $mday, $hour, $min, $sec,
				$env{'username'}, $desc, $id1_url, $id2_url), 1);
	$env{'matches'}++;
	$new_tree_conflicts{$winner} = 1;
}

sub cacheWrite($$$$) {
	my $type	= shift;
	my $string	= shift;
	my $key		= shift;
	my $value	= shift;

	if ($type eq "cache_private_profiles") {
		$cache_private_profiles{$key} = $value;
	} elsif ($type eq "cache_merge_request") {
		$cache_merge_request{$key} = $value;
	} elsif ($type eq "cache_merge_fail") {
		$cache_merge_fail{$key} = $value;
	} elsif ($type eq "cache_no_match") {
		$cache_no_match{$key} = $value;
	} elsif ($type eq "cache_name_mismatch") {
		$cache_name_mismatch{$key} = $value;
	} else {
		die("\n\nERROR: cacheWrite unknown type '$type'\n\n");
	}

	write_file($env{$type}, "$string\n", 1);
}

sub cacheExists($$) {
	my $type	= shift;
	my $key		= shift;

	if ($type eq "cache_private_profiles") {
		return (exists $cache_private_profiles{$key});
	} elsif ($type eq "cache_merge_request") {
		return (exists $cache_merge_request{$key});
	} elsif ($type eq "cache_merge_fail") {
		return (exists $cache_merge_fail{$key});
	} elsif ($type eq "cache_no_match") {
		return (exists $cache_no_match{$key});
	} elsif ($type eq "cache_name_mismatch") {
		return (exists $cache_name_mismatch{$key});
	} else {
		die("\n\nERROR: cacheWrite unknown type '$type'\n\n");
	}
	return 0;
}

sub cacheRead($$) {
	my $type	= shift;
	my $key		= shift;

	if ($type eq "cache_private_profiles") {
		return $cache_private_profiles{$key};
	} elsif ($type eq "cache_merge_request") {
		return $cache_merge_request{$key};
	} elsif ($type eq "cache_merge_fail") {
		return $cache_merge_fail{$key};
	} elsif ($type eq "cache_no_match") {
		return $cache_no_match{$key};
	} elsif ($type eq "cache_name_mismatch") {
		return $cache_name_mismatch{$key};
	} else {
		die("\n\nERROR: cacheWrite unknown type '$type'\n\n");
	}
	return "";
}

sub recordMergeRequest($$) {
	my $id1			= shift;
	my $id2			= shift;
	cacheWrite("cache_merge_request", "$id1:$id2", "$id1:$id2", 1);
}

sub recordMergeFailure($$$) {
	my $id1		= shift;
	my $id2		= shift;
	my $reason	= shift;

	(my $sec, my $min, my $hour, my $mday, my $mon, my $year, my $wday, my $yday, my $isdst) = localtime(time);
	my $fail_string = sprintf("MERGE FAILED for %s at %4d-%02d-%02d %02d:%02d:%02d by %s. Failure reason '%s'<br />\n",
				mergeURLHTML($id1, $id2),
				$year+1900, $mon+1, $mday, $hour, $min, $sec,
				$env{'username'}, $reason);
	write_file($env{'merge_fail_file'}, $fail_string, 1);
	cacheWrite("cache_merge_fail", "$id1:$id2", "$id1:$id2", 1);
}

sub recordNonMatch($$) {
	my $id1	= shift;
	my $id2	= shift;
	cacheWrite("cache_no_match", "$id1:$id2", "$id1:$id2", 1);
}

sub recordNameCompare($$$) {
	my $id1		= shift;
	my $id2		= shift;
	my $result	= shift;
	$result = ($result ? "MATCH" : "NOT_A_MATCH");
	cacheWrite("cache_name_mismatch", "$id1:$id2:$result", "$id1:$id2", $result);
}

sub nameCompareResultCached($$) {
	my $id1	= shift;
	my $id2	= shift;

	if (cacheExists("cache_name_mismatch", "$id1:$id2")) {
		if (cacheRead("cache_name_mismatch", "$id1:$id2") eq "NOT_A_MATCH") {
			printDebug($DBG_PROGRESS, ": (CACHED) NAME MISMATCH\n");
		} else {
			printDebug($DBG_PROGRESS, ": (CACHED) NAME MATCH");
		}
		return $cache_name_mismatch{"$id1:$id2"};
	}

	if (cacheExists("cache_name_mismatch", "$id2:$id1")) {
		if (cacheRead("cache_name_mismatch", "$id2:$id1") eq "NOT_A_MATCH") {
			printDebug($DBG_PROGRESS, ": (CACHED) NAME MISMATCH\n");
		} else {
			printDebug($DBG_PROGRESS, ": (CACHED) NAME MATCH");
		}
		return $cache_name_mismatch{"$id2:$id1"};
	}

	return "";
}

sub compareResultCached($$) {
	my $id1	= shift;
	my $id2	= shift;

	if (cacheExists("cache_no_match", "$id1:$id2") || cacheExists("cache_no_match", "$id2:$id1")) {
		printDebug($DBG_PROGRESS, ": (CACHED) NOT A MATCH\n");
		return 1;
	}

	if (cacheExists("cache_merge_request", "$id1:$id2") || cacheExists("cache_merge_request", "$id2:$id1")) {
		printDebug($DBG_PROGRESS, ": (CACHED) MERGE REQUESTED\n");
		return 1;
	}

	if (cacheExists("cache_merge_fail", "$id1:$id2") || cacheExists("cache_merge_fail", "$id2:$id1")) {
		printDebug($DBG_PROGRESS, ": (CACHED) MERGE FAILED\n");
		return 1;
	}

	return 0;
}

sub loadCache() {
	undef %cache_private_profiles;
	undef %cache_merge_request;
	undef %cache_merge_fail;
	undef %cache_no_match;
	undef %cache_name_mismatch;

	open(FH, $env{'cache_private_profiles'});
	while (<FH>) {
		chomp();
		$cache_private_profiles{$_} = 1;
	}
	close FH;

	open(FH, $env{'cache_merge_request'});
	while (<FH>) {
		chomp();
		$cache_merge_request{$_} = 1;
	}
	close FH;

	open(FH, $env{'cache_merge_fail'});
	while (<FH>) {
		chomp();
		$cache_merge_fail{$_} = 1;
	}
	close FH;

	open(FH, $env{'cache_no_match'});
	while (<FH>) {
		chomp();
		$cache_no_match{$_} = 1;
	}
	close FH;

	open(FH, $env{'cache_name_mismatch'});
	while (<FH>) {
		chomp();
		if (/(\d+):(\d+):(.*)$/) {
			$cache_name_mismatch{"$1\:$2"} = $3;
		}
	}
	close FH;
}

sub compareNamesGuts($$$) {
	my $compare_initials = shift;
	my $left_name	= shift;
	my $right_name	= shift;

	if ($left_name =~ /living/ || $right_name =~ /living/) {
		return 0;
	}
	if ($left_name =~ /unknown/ || $right_name =~ /unknown/) {
		return 0;
	}
	if ($left_name && !$right_name) {
		return 1;
	}
	if (!$left_name && $right_name) {
		return 1;
	}
	if ($left_name eq $right_name) {
		return 1;
	}

	# This can only happen if we're looking at a profile with multiple middle names.
	# If that is the case then don't consider "R. vs. Robert" a match.  The reason
	# being there could be 5 middle names and it would be too easy for one of them 
	# to match an initial.
	if ($left_name =~ /\s/ || $right_name =~ /\s/) {
		$compare_initials = 0;
	}

	# Replace the _or_ with a space so the names get split for the foreach loop below
	$left_name =~ s/_or_/ /g;
	$right_name =~ s/_or_/ /g;

	# Again, this only happens for multiple middle names.  We compare all the middle
	# names from the left profile with the middle names from the right profile. If
	# one of them matches return true. This is designed for cases like this:
	# 'sarah dabney taylor (strother)' vs. right 'sarah pannill dabney taylor (strother)'
	foreach my $left_name_component (split(/\s/, $left_name)) {
		foreach my $right_name_component (split(/\s/, $right_name)) {
			
			if ($left_name_component eq $right_name_component) {
				return 1;
			}
			if ($compare_initials && initialVsWholeMatch($left_name_component, $right_name_component)) {
				return 1;
			}
			if (doubleMetaphoneCompare($left_name_component, $right_name_component)) {
				return 1;
			}
		}
	}
	return 0;
}

sub updateLastMaidenNames($$$) {
	my $last_name	= shift;
	my $maiden_name	= shift;
	my $profile_id	= shift;

	# If the profile is private we won't be able to get any additional information
	if (cacheExists("cache_private_profiles", "$profile_id")) {
		return ($last_name, $maiden_name);
	}

	# If the we couldn't get enough info just return the names we already have
	(my $father_last_name, my $husband_last_name) = getMaleLastNames($profile_id);
	if ($father_last_name eq "" && $husband_last_name eq "") {
		return ($last_name, $maiden_name);
	}

	if ($husband_last_name && $husband_last_name ne $last_name) {
		if ($maiden_name eq "") {
			printDebug($DBG_NAMES, "Changing maiden name from '' to '$last_name'\n");
			$maiden_name = $last_name;
		}
		printDebug($DBG_NAMES, "Changing last name from '$last_name' to '$husband_last_name'\n");
		$last_name = $husband_last_name;
	}

	if ($father_last_name && (!$maiden_name || $maiden_name eq $husband_last_name)) {
		printDebug($DBG_NAMES, "Changing maiden name from '$maiden_name' to '$father_last_name'\n");
		$maiden_name = $father_last_name;
	}

	return ($last_name, $maiden_name);
}

# Return TRUE if they match
sub compareNames($$$$$$) {
	my $gender		= shift;
	my $left_name		= shift;
	my $left_profile_id	= shift;
	my $right_name		= shift;
	my $right_profile_id	= shift;
	my $debug		= shift;
	my $cache_result	= 0;

	if ($left_name eq $right_name) {
		if ($left_name =~ /living/ || $left_name =~ /unknown/) {
			return 0;
		}
		printDebug($DBG_NONE,
			sprintf("MATCH Whole Name: left '%s' vs. right '%s'\n",
				$left_name,
				$right_name)) if $debug;
		return 1;
	}

	# It one name is blank then be conservative and return false
	if (!$left_name || !$right_name) {
		return 0;
	}

	(my $left_first_name, my $left_middle_name, my $left_last_name, my $left_maiden_name) = nameToFirstMiddleLastMaiden($left_name); 
	(my $right_first_name, my $right_middle_name, my $right_last_name, my $right_maiden_name) = nameToFirstMiddleLastMaiden($right_name); 

	my $first_name_matches = compareNamesGuts(1, $left_first_name, $right_first_name);
	printDebug($DBG_NONE,
		sprintf("%sMATCH First Name: left '%s' vs. right '%s'\n",
			($first_name_matches) ? "" : "NO_",
			$left_first_name,
			$right_first_name)) if $debug;
	if (!$first_name_matches) {
		return 0;
	}

	my $middle_name_matches = compareNamesGuts(1, $left_middle_name, $right_middle_name);
	printDebug($DBG_NONE,
		sprintf("%sMATCH Middle Name: left '%s' vs. right '%s'\n",
			($middle_name_matches) ? "" : "NO_",
			$left_middle_name,
			$right_middle_name)) if $debug;
	if (!$middle_name_matches) {
		return 0;
	}

	# If the female only has a last name or only has a maiden name then try to determine the other
	if ($gender eq "female") {
		if (!$left_maiden_name || $left_last_name eq $left_maiden_name) {
			($left_last_name, $left_maiden_name) = updateLastMaidenNames($left_last_name, $left_maiden_name, $left_profile_id);
			$cache_result = 1;
		}

		if (!$right_maiden_name || $right_last_name eq $right_maiden_name) {
			($left_last_name, $left_maiden_name) = updateLastMaidenNames($right_last_name, $right_maiden_name, $right_profile_id);
			$cache_result = 1;
		}
	}

	my $last_name_matches = 0;
	if ($gender eq "female") {
		$left_maiden_name = $left_last_name if ($left_maiden_name eq "");
		$right_maiden_name = $right_last_name if ($right_maiden_name eq "");
		$last_name_matches = compareNamesGuts(0, $left_maiden_name, $right_maiden_name) ||
				     compareNamesGuts(0, $left_last_name, $right_last_name);
	} else {
		$last_name_matches = compareNamesGuts(0, $left_last_name, $right_last_name);
	}

	if ($gender eq "female") {
		printDebug($DBG_NONE,
			sprintf("%sMATCH Last Name: left '%s (%s)' vs. right '%s (%s)'\n",
				($last_name_matches) ? "" : "NO_",
				$left_last_name,
				$left_maiden_name,
				$right_last_name,
				$right_maiden_name)) if $debug;
	} else {
		printDebug($DBG_NONE,
			sprintf("%sMATCH Last Name: left '%s' vs. right '%s'\n",
				($last_name_matches) ? "" : "NO_",
				$left_last_name,
				$right_last_name)) if $debug;
	}

	# This should never happen but just to be safe return false if everything is blank
	if (!$left_first_name && !$left_middle_name && !$left_last_name && !$left_maiden_name &&
	    !$right_first_name && !$right_middle_name && !$right_last_name && !$right_maiden_name) {
		printDebug($DBG_PROGRESS, "ERROR: compareNames all names were blank\n");
		return 0;
	}

	recordNameCompare($left_profile_id, $right_profile_id, $last_name_matches) if ($cache_result);
	return $last_name_matches;
}

#
# Return TRUE if the names, dates, etc for the two profiles match
#
sub profileBasicsMatch($$) {
	my $left_profile = shift;
	my $right_profile = shift;
	my $score = 0;

	my $left_name = 
		cleanupName($left_profile->first_name,
			$left_profile->middle_name,
			$left_profile->last_name,
			$left_profile->maiden_name);

	my $right_name =
		cleanupName($right_profile->first_name,
			$right_profile->middle_name,
			$right_profile->last_name,
			$right_profile->maiden_name);

	if ($left_profile->gender ne $right_profile->gender) {
		printDebug($DBG_MATCH_BASIC,
			sprintf("NO_MATCH: gender '%s' ne '%s'\n",
				$left_profile->gender,
				$right_profile->gender));
		return 0;
	}

	if ($left_profile->living ne $right_profile->living) {
		printDebug($DBG_MATCH_BASIC,
			sprintf("NO_MATCH: living '%s' does not equal '%s'\n",
				$left_profile->living,
				$right_profile->living));
		return 0;
	}

	if (!dateMatches($left_profile->death_year, $right_profile->death_year)) {
		printDebug($DBG_MATCH_BASIC,
			sprintf("NO_MATCH: death year '%s' does not equal '%s'\n",
				$left_profile->death_year,
				$right_profile->death_year));
		return 0;
	}

	if (!dateMatches($left_profile->death_date, $right_profile->death_date)) {
		printDebug($DBG_MATCH_BASIC,
			sprintf("NO_MATCH: death date '%s' does not equal '%s'\n",
				$left_profile->death_date,
				$right_profile->death_date));
		return 0;
	}

	if (!dateMatches($left_profile->birth_year, $right_profile->birth_year)) {
		printDebug($DBG_MATCH_BASIC,
			sprintf("NO_MATCH: birth year '%s' does not equal '%s'\n",
				$left_profile->birth_year,
				$right_profile->birth_year));
		return 0;
	}

	if (!dateMatches($left_profile->birth_date, $right_profile->birth_date)) {
		printDebug($DBG_MATCH_BASIC,
			sprintf("NO_MATCH: birth date '%s' does not equal '%s'\n",
				$left_profile->birth_date,
				$right_profile->birth_date));
		return 0;
	}

	# Comparing names can be expensive (it may require multiple API calls) so
	# do this last after everything else has matched
	if (!compareNames($left_profile->gender, $left_name, $left_profile->id, $right_name, $right_profile->id, 1)) {
		printDebug($DBG_MATCH_BASIC,
			sprintf("NO_MATCH: name '%s' ne '%s'\n",
				$left_name,
				$right_name));
		return 0;
	}

	printDebug($DBG_MATCH_BASIC,
		sprintf("MATCH: %s's basic profile data matches\n",
			$left_name));

	return 1;
}

sub comparePartners($$$$) {
	my $gender		= shift;
	my $partner_type	= shift;
	my $left_partners	= shift;
	my $right_partners	= shift;

	if (($left_partners && !$right_partners) || (!$left_partners && $right_partners)) { 
		return 1;
	}

	# printDebug($DBG_MATCH_BASIC, "$partner_type:\n");
	# printDebug($DBG_MATCH_BASIC, sprintf("-left  : %s\n", $left_partners));
	# printDebug($DBG_MATCH_BASIC, sprintf("-right : %s\n", $right_partners));

	if ($left_partners eq $right_partners && !$left_partners) { 
		printDebug($DBG_MATCH_BASIC, "MATCH: $partner_type '$left_partners' are a match\n");
		return 1;
	}

	foreach my $person1 (split(/::/, $left_partners)) {
		(my $person1_id, my $person1_name, my $person1_gender) = split(/:/, $person1);

		foreach my $person2 (split(/::/, $right_partners)) {
			(my $person2_id, my $person2_name, my $person2_gender) = split(/:/, $person2);
			next if ($person1_gender ne $person2_gender);

			if (compareNames($person1_gender, $person1_name, $person1_id, $person2_name, $person2_id, 1)) {
				printDebug($DBG_MATCH_BASIC, "MATCH: $partner_type '$person1_name' is a match.\n");
				return 1;
			}
		}
	}

	printDebug($DBG_MATCH_BASIC, "NO_MATCH: $partner_type do not match\n");
	printDebug($DBG_MATCH_BASIC, "Left Profile $partner_type:\n");
	foreach my $person (split(/::/, $left_partners)) {
		(my $person_id, my $person_name, my $person_gender) = split(/:/, $person);
		printDebug($DBG_MATCH_BASIC, "- <a href=\"http://www.geni.com/profile-$person_id\">$person_name</a>\n");
	}

	printDebug($DBG_MATCH_BASIC, "Right Profile $partner_type:\n");
	foreach my $person (split(/::/, $right_partners)) {
		(my $person_id, my $person_name, my $person_gender) = split(/:/, $person);
		printDebug($DBG_MATCH_BASIC, "- <a href=\"http://www.geni.com/profile-$person_id\">$person_name</a>\n");
	}

	return 0;
}

sub avoidDuplicatesPush($$) {
	my $value_array = shift;
	my $value_to_add= shift;

	foreach my $value (@$value_array) {
		return if ($value eq $value_to_add);
	}

	push @$value_array, $value_to_add;
}

sub mergeURLHTML($$) {
	my $id1			= shift;
	my $id2			= shift;
	
 	# http://www.geni.com/profile-101/compare/profile-102
	return "<a href=\"http://www.geni.com/profile-$id1/compare/profile-$id2\">$id1 vs. $id2</a>";
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
	sleepIfNeeded();
	$m->get($url) || die "getPage($url) failed";
	write_file($filename, $m->content(), 0);
	updateGetHistory("getPage");
}

sub getJSON($$$$) {
	my $filename	= shift;
	my $url		= shift;
	my $id1		= shift;
	my $id2		= shift;

	getPage($filename, $url);
	if (jsonSanityCheck($filename) == 0) {
		printDebug($DBG_PROGRESS, "JSON_SANITY_FAILED: $url\n");
		unlink $filename if $env{'delete_files'};
		return 0;

	# If one of the profiles involved is marked as private and we were
	# able to convert it to public then download the json again.
	} elsif (jsonIsPrivate($filename)) {
		my $try_again = 0;
		$try_again = 1 if ($id1 && checkPublic($id1));
		$try_again = 1 if ($id2 && checkPublic($id2));
		if (!$try_again) {
			return 0;
		}

		unlink $filename;
		getPage($filename, $url);

		if (jsonIsPrivate($filename)) {
			return 0;
		}

		if (jsonSanityCheck($filename) == 0) {
			printDebug($DBG_PROGRESS, "JSON_SANITY_FAILED: $url\n");
			return 0;
		}
	}

	open (INF,$filename);
	my $json_data = <INF>;
	my $json = new JSON;
	my $json_structure = $json->allow_nonref->relaxed->decode($json_data);
	close INF;

	printDebug($DBG_JSON, sprintf ("Pretty JSON:\n%s", $json->pretty->encode($json_structure))); 
	return $json_structure;
}

sub compareProfiles($$) {
	my $id1			= shift;
	my $id2			= shift;
	my $id1_url = "<a href=\"http://www.geni.com/profile-$id1\">$id1</a>";
	my $id2_url = "<a href=\"http://www.geni.com/profile-$id2\">$id2</a>";

	if (!$id1 || !$id2) {
		printDebug($DBG_PROGRESS, "ERROR: compareProfiles was given an invalid id1 '$id1' or id2 '$id2'\n");
		return 0;
	}
	my $profiles_url = "https://www.geni.com/api/profile-$id1/compare/profile-$id2?only_ids=true";
	my $filename = sprintf("$env{'datadir'}/%s-%s.json", $id1, $id2);
	my $json_text = getJSON($filename, $profiles_url, $id1, $id2);
	if (!$json_text) {
		return 0;
	}
	printDebug($DBG_NONE, sprintf("\nComparing %s ($id1_url, $id2_url)\n", mergeURLHTML($id1, $id2)));

	my $left_profile = new profile;
	my $right_profile= new profile;
	my $geni_profile = $left_profile;
	foreach my $json_profile (@{$json_text->{'results'}}) {

		# Never ever ever ever ever ever ever ever try to merge with a claimed profile.
		# If it is a historical profile this can cause all kinds of private profile
		# issues in that part of the tree.
		if ($json_profile->{'focus'}->{'claimed'} ne "false") {
			printDebug($DBG_NONE,
				sprintf("NO_MATCH: %s is a claimed profile\n",
					($geni_profile == $left_profile) ? $id1_url : $id2_url));
			unlink $filename if $env{'delete_files'};
			return 0;
		}

		# If the profile isn't on the big tree then don't merge it.
		if (!$env{'merge_little_trees'} && $json_profile->{'focus'}->{'big_tree'} ne "true") {
			printDebug($DBG_NONE,
				sprintf("NO_MATCH: %s is not on the big tree\n",
					($geni_profile == $left_profile) ? $id1_url : $id2_url));
			unlink $filename if $env{'delete_files'};
			return 0;
		}

		# If the profile has a curator note asking that the profile not be merged then skip it.
		if ($json_profile->{'focus'}->{'merge_note'} =~ /merg/i ||
		    $json_profile->{'focus'}->{'merge_note'} =~ /work in progress/i ||
		    $json_profile->{'focus'}->{'merge_note'} =~ /WIP/) {
			printDebug($DBG_NONE,
				sprintf("NO_MATCH: %s has a curator note '%s'\n",
					($geni_profile == $left_profile) ? $id1_url : $id2_url,
					$json_profile->{'focus'}->{'merge_note'}));
			unlink $filename if $env{'delete_files'};
			return 0;
		}

		# They keep changing the format for how they list managers :( 
		# Make this work for the old and new format and bail out if 
		# they change it again. 
		my @managers; 
		if(ref($json_profile->{'focus'}->{'managers'}) eq "ARRAY") { #arrayref 
			foreach my $manager_line (@{$json_profile->{'focus'}->{'managers'}}) { 
				if ($manager_line =~ /profiles\/(.*)$/) { 
					push @managers, split(/,/, $1); 
				} elsif ($manager_line =~ /^profile-(\d+)$/) { 
					push @managers, $1; 
				} else { 
					gracefulExit("ERROR: Manager line '$manager_line' is invalid.\n"); 
				} 
			} 
		}elsif(ref($json_profile->{'focus'}->{'managers'}) eq 'SCALAR'){ 
			my @a = split(/\D+/,$$json_profile->{'focus'}->{'managers'}); 
			foreach(@a){ 
				if(length($_) > 5){ push @managers, $_; } 
			} 
		}

		# Do not merge a profile managed by any of the blacklist_managers
		foreach my $profile_id (@managers) {
			if ($blacklist_managers{$profile_id}) {
				printDebug($DBG_NONE,
					sprintf("NO_MATCH: %s is managed by blacklist user %s\n",
						($geni_profile == $left_profile) ? $id1_url : $id2_url,
						"<a href=\"http://www.geni.com/profile-$profile_id/\">$profile_id</a>\n"));
				unlink $filename if $env{'delete_files'};
				return 0;
			}
		}

		$geni_profile->first_name($json_profile->{'focus'}->{'first_name'});
		$geni_profile->middle_name($json_profile->{'focus'}->{'middle_name'});
		$geni_profile->last_name($json_profile->{'focus'}->{'last_name'});
		$geni_profile->maiden_name($json_profile->{'focus'}->{'maiden_name'});
		$geni_profile->suffix($json_profile->{'focus'}->{'suffix'});
		$geni_profile->gender($json_profile->{'focus'}->{'gender'});
		$geni_profile->living($json_profile->{'focus'}->{'living'});
		$geni_profile->death_date($json_profile->{'focus'}->{'death_date'});
		$geni_profile->death_year($json_profile->{'focus'}->{'death_year'});
		$geni_profile->birth_date($json_profile->{'focus'}->{'birth_date'});
		$geni_profile->birth_year($json_profile->{'focus'}->{'birth_year'});
		$geni_profile->public($json_profile->{'focus'}->{'public'});
		my $profile_id = $json_profile->{'focus'}->{'id'};
		$profile_id =~ s/profile-//g;
		$geni_profile->id($profile_id);

		if ($geni_profile->public eq "false" && checkPublic($profile_id)) {
			$geni_profile->public("true");
		}
		
		my @fathers, my @mothers, my @spouses, my @sons, my @daughters, my @brothers, my @sisters;
		jsonToFamilyArrays($json_profile, $profile_id, \@fathers, \@mothers, \@spouses, \@sons, \@daughters, \@brothers, \@sisters);
		$geni_profile->fathers(join("::", @fathers));
		$geni_profile->mothers(join("::", @mothers));
		$geni_profile->spouses(join("::", @spouses));
		$geni_profile = $right_profile;
	}

	unlink $filename if $env{'delete_files'};

	# This is a big safety net in case in case the API somehow were to
	# return a different merge comparison than what we asked for
	if (($left_profile->id ne $id1 && $left_profile->id ne $id2) ||
	    ($right_profile->id ne $id1 && $right_profile->id ne $id2)) {
		printDebug($DBG_NONE,
			sprintf("WEIRD: asked for '%s' and '%s' but got '%s' and '%s'\n",
				$id1, $id2, $left_profile->id, $right_profile->id));
		return 0;
	}

	if (profileBasicsMatch($left_profile, $right_profile) == 0) {
		return 0;
	}

	if (!comparePartners("male", "fathers", $left_profile->fathers, $right_profile->fathers)) {
		return 0;
	}

	if (!comparePartners("female", "mothers", $left_profile->mothers, $right_profile->mothers)) {
		return 0;
	}

	if (!comparePartners("female", "spouses", $left_profile->spouses, $right_profile->spouses)) {
		return 0;
	}

	printDebug($DBG_MATCH_BASIC, "MATCH: parents and spouses match\n");
	return 1;
}

#
# Update the get_history file with the current timestamp
#
sub updateGetHistory($) {
	my $caller = shift;
	(my $time_sec, my $time_usec) = Time::HiRes::gettimeofday();
	push @get_history, "$time_sec.$time_usec\n";
	printDebug($DBG_TIME, "updateGetHistory for $caller: $time_sec.$time_usec\n");
}

sub mergeProfiles($$$) {
	my $id1			= shift;
	my $id2			= shift;
	my $desc		= shift;
	my $merge_url_api	= "https://www.geni.com/api/profile-$id1/merge/profile-$id2";
	my $id1_url = "<a href=\"http://www.geni.com/profile-$id1\">$id1</a>";
	my $id2_url = "<a href=\"http://www.geni.com/profile-$id2\">$id2</a>";
	my $winner = 0;

	geniLogin() if !$env{'logged_in'};
	sleepIfNeeded();
	my $result = new HTTP::Response;
	$result = $m->post($merge_url_api);
	updateGetHistory("mergeProfiles");
	(my $sec, my $min, my $hour, my $mday, my $mon, my $year, my $wday, my $yday, my $isdst) = localtime(time);

	if ($result->is_success) {

		# This happens if at least one of the profiles you tried to merge is private
		if ($result->decoded_content =~ /requested for a merge/i) {
			printDebug($DBG_PROGRESS, sprintf(": MERGE REQUESTED for %s and %s\n", $id1, $id2));
			recordMergeRequest($id1, $id2);

		# The merge was ok
		} else {
			# printDebug($DBG_PROGRESS, sprintf("\nMERGE_RESULT: %s\n", $result->decoded_content));
			if ($result->decoded_content =~ /profile-\d+ merged into profile-(\d+)/) {
				$winner = $1;
			}
			if ($winner == 0) {
				die(sprintf("ERROR: %d and %d did not produce a winner, result'%s'\n", $id1, $id2, $result->decoded_content));
			}
			printDebug($DBG_PROGRESS, sprintf(": MERGE COMPLETED for %s and %s, winner %d\n", $id1, $id2, $winner));
			recordMergeComplete($id1, $id2, $desc, $winner);
		}
	} else {
		printDebug($DBG_PROGRESS, sprintf(": MERGE FAILED for %s and %s due to %s\n", $id1, $id2, $result->decoded_content));
		recordMergeFailure($id1, $id2, $result->decoded_content);
	}

	return ($winner);
}

sub compareAllProfiles($$) {
	my $text		= shift;
	my $profiles_array_ptr	= shift;
	my @profiles_array = @$profiles_array_ptr;
	my $profile_count = 0;
	my $match_count = 0;

	for (my $i = 0; $i <= $#profiles_array; $i++) {
		if ($profiles_array[$i] eq "SKIP_THIS_ONE") {
			print "TREE_CONFLICT_COMPARE: $text\[$i] has already been merged into another profile....skipping\n";
			next;
		}

		(my $i_id, my $i_name, my $gender) = split(/:/, $profiles_array[$i]);

		for (my $j = $i + 1; $j <= $#profiles_array; $j++) {
			$profile_count++;

			if ($profiles_array[$j] eq "SKIP_THIS_ONE") {
				print "TREE_CONFLICT_COMPARE: $text\[$j] has already been merged into another profile....skipping\n";
				next;
			}

			(my $j_id, my $j_name, my $gender) = split(/:/, $profiles_array[$j]);

			printDebug($DBG_PROGRESS, "TREE_CONFLICT_COMPARE: $text\[$i] $i_name vs. $text\[$j] $j_name");
			next if (nameCompareResultCached($i_id, $j_id) eq "NOT_A_MATCH");
			next if (compareResultCached($i_id, $j_id));

			if (compareNames($gender, $i_name, $i_id, $j_name, $j_id, 0)) {
				if (compareProfiles($i_id, $j_id)) {
					printDebug($DBG_PROGRESS, ": MATCH\n");
					my $winner = mergeProfiles($i_id, $j_id, "TREE_CONFLICT");
					$match_count++;
					if ($winner == $j_id) {
						if ($j < $#profiles_array) {
							printDebug($DBG_PROGRESS, sprintf("%s\[%s] was the winner of the merge so skipping %s\[%s] vs. %s[%s] -> %s[%s]\n",
											$text, $j, $text, $i, $text, $j + 1, $text, $#profiles_array));
							last;
						}
					} elsif ($winner == $i_id) {
						$profiles_array[$j] = "SKIP_THIS_ONE";
					}
				} else {
					printDebug($DBG_PROGRESS, ": NO_MATCH\n");
					recordNonMatch($i_id, $j_id);
				}
			} else {
				printDebug($DBG_PROGRESS, ": NAME MISMATCH\n");
			}
		}
	}
	return ($profile_count, $match_count);
}

sub checkPublic($) {
	my $profile_id	= shift;
	if (!$profile_id) {
		return 0;
	}

	if (cacheExists("cache_private_profiles", "$profile_id")) {
		printDebug($DBG_NONE, "\nPRIVATE_PROFILE (CACHED): $profile_id\n");
		return 0;
	}

	geniLogin() if !$env{'logged_in'};
	sleepIfNeeded();
	my $result = new HTTP::Response;
	$result = $m->post("https://www.geni.com/api/profile-$profile_id/check-public");
	updateGetHistory("checkPublic");

	my $profile_is_public = ($result->is_success && $result->decoded_content =~ /true/);
	if ($profile_is_public) {
		# todo: if we ever get a hunt_zombies API this is the scenario where we should run it
		printDebug($DBG_NONE,
			"\nPRIVATE_PROFILE: $profile_id was converted from private to public\n");
	} else {
		printDebug($DBG_NONE,
			"\nPRIVATE_PROFILE: $profile_id could not be converted from private to public\n");
		cacheWrite("cache_private_profiles", "$profile_id", "$profile_id", 1);
	}

	return $profile_is_public;
}

sub analyzeTreeConflict($$) {
	my $profile_id	= shift;
	my $issue_type	= shift;
	
	if ($profile_id =~ /profiles\/(\d+)/) {
		$profile_id = $1;
	}

	my @fathers, my @mothers, my @spouses, my @sons, my @daughters, my @brothers, my @sisters;
	my $filename = "$env{'datadir'}/$profile_id\.json";
	my $url = "https://www.geni.com/api/profile-$profile_id/immediate-family?only_ids=true";
	my $json_profile = getJSON($filename, $url, $profile_id, 0);
	if (!$json_profile) {
		return 0;
	}

	jsonToFamilyArrays($json_profile, $profile_id, \@fathers, \@mothers, \@spouses, \@sons, \@daughters, \@brothers, \@sisters);
	my $ugly_count = 0;
	$ugly_count += $#fathers + 1 if ($#fathers >= 0); 
	$ugly_count += $#mothers + 1 if ($#mothers >= 0); 
	$ugly_count += $#spouses + 1 if ($#spouses >= 0); 
	write_file($env{'ugly_file'}, "$ugly_count <a href=\"http://www.geni.com/profile-$profile_id\">$profile_id</a>\n", 1);

	my $profile_count = 0;
	my $match_count = 0;
	my $a, my $b;
	$env{'circa_range'} = 5;
	if ($issue_type eq "parent") {
		printDebug($DBG_PROGRESS,
			sprintf("Tree Conflict analyze for '%d', type '%s', fathers %d, mothers %d\n",
				$profile_id, $issue_type, $#fathers, $#mothers));

		($a, $b) = compareAllProfiles("Father", \@fathers); $profile_count += $a; $match_count += $b;
		($a, $b) = compareAllProfiles("Mother", \@mothers); $profile_count += $a; $match_count += $b;
	}

	if ($issue_type eq "partner") {
		printDebug($DBG_PROGRESS,
			sprintf("Tree Conflict analyze for '%d', type '%s', spouses %d\n",
				$profile_id, $issue_type, $#spouses));
		($a, $b) = compareAllProfiles("Spouse", \@spouses); $profile_count += $a; $match_count += $b;
	}

	# todo: need a better way to handle this if the profiles we're comparing have spouses.
	# We could go back to +- 5 for those cases.
	$env{'circa_range'} = 1;
	if ($issue_type eq "children") {
		printDebug($DBG_PROGRESS,
			sprintf("Tree Conflict analyze for '%d', type '%s', sons %d, daughters %d\n",
				$profile_id, $issue_type, $#sons, $#daughters));
		($a, $b) = compareAllProfiles("Sons", \@sons); $profile_count += $a; $match_count += $b;
		($a, $b) = compareAllProfiles("Daughters", \@daughters); $profile_count += $a; $match_count += $b;
	}

	if ($issue_type eq "siblings") {
		printDebug($DBG_PROGRESS,
			sprintf("Tree Conflict analyze for '%d', type '%s', brothers %d, sisters %d\n",
				$profile_id, $issue_type, $#brothers, $#sisters));
		($a, $b) = compareAllProfiles("Brothers", \@brothers); $profile_count += $a; $match_count += $b;
		($a, $b) = compareAllProfiles("Sisters", \@sisters); $profile_count += $a; $match_count += $b;
	}

	$env{'circa_range'} = 5;
	unlink $filename if ($env{'delete_files'} && $match_count);
}

# Resolve any new tree conflicts that were created. This could in turn
# create more tree conflicts so this loop could run for a while.
sub analyzeNewTreeConflicts() {
	if (!(scalar keys %new_tree_conflicts)) {
		return;
	}

	do {
		printDebug($DBG_PROGRESS,
			sprintf("\n\nNEW_TREE_CONFLICTS: Analyzing new tree conflicts, there are %d of them\n",
				scalar keys %new_tree_conflicts));

		foreach my $id (keys %new_tree_conflicts) {
			analyzeTreeConflict($id, "parent");
			analyzeTreeConflict($id, "siblings");
			analyzeTreeConflict($id, "partner");
			analyzeTreeConflict($id, "children");
			delete $new_tree_conflicts{$id};
			unlink "$env{'datadir'}/$id\.json" if ($env{'delete_files'});
		}
	} while (scalar keys %new_tree_conflicts);
}

sub jsonToFamilyArrays($$$$$$$$$) {
	my $json_profile	= shift;
	my $profile_id		= shift;
	my $fathers_ptr		= shift;
	my $mothers_ptr		= shift;
	my $spouses_ptr		= shift;
	my $sons_ptr		= shift;
	my $daughters_ptr	= shift;
	my $brothers_ptr	= shift;
	my $sisters_ptr		= shift;

	my @fathers	= @$fathers_ptr;
	my @mothers	= @$mothers_ptr;
	my @spouses	= @$spouses_ptr;
	my @sons	= @$sons_ptr;
	my @daughters	= @$daughters_ptr;
	my @brothers	= @$brothers_ptr;
	my @sisters	= @$sisters_ptr;

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
			$id =~ s/profile-//;
			my $first_name = $json_profile->{'nodes'}->{$j}->{'first_name'};
			my $middle_name = $json_profile->{'nodes'}->{$j}->{'middle_name'};
			my $last_name = $json_profile->{'nodes'}->{$j}->{'last_name'};
			my $maiden_name = $json_profile->{'nodes'}->{$j}->{'maiden_name'};
			my $public = $json_profile->{'nodes'}->{$j}->{'public'};
			my $name = cleanupName($first_name, $middle_name, $last_name, $maiden_name);
			my $push_string = "$id:$name:$gender";

			# A "hidden_child" is just a placeholder profile and can be ignored
			next if ($rel eq "hidden_child");

			if ($public eq "false" && checkPublic($id)) {
				$public = "true"
			}

			if ($id eq "") {
				printDebug($DBG_PROGRESS, "ERROR: $i $j is missing from the json\n");
				next;
			}
			
			# If the name is something like "Daughter" or "Unknown" then that
			# will cleanup down to nothing so be conservative and skip it.
			next if (!$name);

			if ($rel eq "partner") {
				if ($partner_type eq "parents") {
					if ($gender eq "male") {
						avoidDuplicatesPush($fathers_ptr, $push_string);
					} elsif ($gender eq "female") {
						avoidDuplicatesPush($mothers_ptr, $push_string);
					}
				} elsif ($partner_type eq "spouses") {
					avoidDuplicatesPush($spouses_ptr, $push_string);
				}

			} elsif ($rel eq "child") {

				if ($partner_type eq "parents") {
					if ($gender eq "male") {
						avoidDuplicatesPush($brothers_ptr, $push_string);
					} elsif ($gender eq "female") {
						avoidDuplicatesPush($sisters_ptr, $push_string);
					}
				} elsif ($partner_type eq "spouses") {
					if ($gender eq "male") {
						avoidDuplicatesPush($sons_ptr, $push_string);
					} elsif ($gender eq "female") {
						avoidDuplicatesPush($daughters_ptr, $push_string);
					}
				}

			} else {
				printDebug($DBG_NONE, "ERROR: unknown rel type '$rel'\n");
			}
		}
	}
}

sub analyzeTreeConflictRecursive($) {
	my $profile_id = shift;

	# First merge everything you can for the profile that is our starting point
	analyzeTreeConflict($profile_id, "parent");
	analyzeTreeConflict($profile_id, "siblings");
	analyzeTreeConflict($profile_id, "partner");
	analyzeTreeConflict($profile_id, "children");
	unlink "$env{'datadir'}/$profile_id\.json" if ($env{'delete_files'});

	my @fathers, my @mothers, my @spouses, my @sons, my @daughters, my @brothers, my @sisters;
	my $filename = "$env{'datadir'}/$profile_id\.json";
	my $url = "https://www.geni.com/api/profile-$profile_id/immediate-family?only_ids=true";
	my $json_profile = getJSON($filename, $url, $profile_id, 0);
	if (!$json_profile) {
		return 0;
	}

	# Then build arrays of all the immediate family members of the starting profile
	jsonToFamilyArrays($json_profile, $profile_id, \@fathers, \@mothers, \@spouses, \@sons, \@daughters, \@brothers, \@sisters);

	# Then resolve the tree conflicts for the immediate family members
	my @parents_and_spouses;
	push @parents_and_spouses, @fathers;
	push @parents_and_spouses, @mothers;
	push @parents_and_spouses, @spouses;
	foreach my $family_member (@parents_and_spouses) {
		(my $id, my $name, my $gender) = split(/:/, $family_member);
		printDebug($DBG_PROGRESS, "PARENT or SPOUSE: $id\n");
		analyzeTreeConflict($id, "parent");
		analyzeTreeConflict($id, "siblings");
		analyzeTreeConflict($id, "partner");
		unlink "$env{'datadir'}/$id\.json" if ($env{'delete_files'});
	}

	my @siblings;
	push @siblings, @brothers;
	push @siblings, @sisters;
	foreach my $family_member (@siblings) {
		(my $id, my $name, my $gender) = split(/:/, $family_member);
		printDebug($DBG_PROGRESS, "SIBLING: $id\n");
		analyzeTreeConflict($id, "partner");
		analyzeTreeConflict($id, "children");
		unlink "$env{'datadir'}/$id\.json" if ($env{'delete_files'});
	}

	my @children;
	push @children, @sons;
	push @children, @daughters;
	foreach my $family_member (@children) {
		(my $id, my $name, my $gender) = split(/:/, $family_member);
		printDebug($DBG_PROGRESS, "CHILD: $id\n");
		analyzeTreeConflict($id, "partner");
		analyzeTreeConflict($id, "children");
		unlink "$env{'datadir'}/$id\.json" if ($env{'delete_files'});
	}

	printDebug($DBG_PROGRESS, "$env{'matches'} matches via immediate family members\n");

	analyzeNewTreeConflicts();
	printDebug($DBG_PROGRESS, "$env{'matches'} matches via extended family\n");
}

sub analyzePendingMerge($$) {
	my $id1			= shift;
	my $id2			= shift;

	# This shouldn't happen but sometimes does due to a bug in
	# geni's code that produces the pending merges list.
	return if ($id1 eq $id2);

	return if (compareResultCached($id1, $id2));

	if (compareProfiles($id1, $id2)) {
		mergeProfiles($id1, $id2, "PENDING_MERGE");
	} else {
		printDebug($DBG_PROGRESS, ": NOT A MATCH\n");
		recordNonMatch($id1, $id2);
	}
}

# Not supported yet
sub analyzeTreeMatch($) {
	my $id1			= shift;
	printDebug($DBG_PROGRESS, "NOTE: Tree Match analysis is not supported yet\n");
	exit();
}

# Not supported yet (probably won't implement this one)
sub analyzeDataConflict($) {
	my $id1			= shift;
	printDebug($DBG_PROGRESS, "NOTE: Data Conflict analysis is not supported yet\n");
	exit();
}

sub stackProfiles($$) {
	my $primary_id		= shift;
	my $IDs_to_stack	= shift;

	geniLogin() if !$env{'logged_in'};
	my $primary_url = "<a href=\"http://www.geni.com/profile-$primary_id\">$primary_id</a>";
	$IDs_to_stack =~ s/ //g;
	foreach my $id (split(/,/, $IDs_to_stack)) {
		if ($id !~ /^\d+$/) {
			printDebug($DBG_PROGRESS, "ERROR: '$id' is not a valid profile ID\n");
		}

		my $id_url = "<a href=\"http://www.geni.com/profile-$id\">$id</a>";

		printDebug($DBG_PROGRESS, "\nStacking Primary $primary_id: Stacking Secondary $id");
		printDebug($DBG_NONE, "\nStacking Primary $primary_url: Stacking Secondary $id_url\n");
		mergeProfiles($primary_id, $id, "STACKING_MERGE");
	}
}

sub rangeBeginEnd($$$$) {
	my $range_begin = shift;
	my $range_end   = shift;
	my $type	= shift;
	my $api_action	= shift;

	my $filename = sprintf("%s/%s_count.json",
				$env{'datadir'}, $api_action);
	# Delete the file so we'll recalculate max_page everytime
	unlink $filename;
	printf STDERR ("https://www.geni.com/api/profile/%s?%s&count=true%s\n",
			$api_action,
			$env{'all_of_geni'} ? "all=true" : "collaborators=true",
			$env{'yesterday'} ? "&since=yesterday" : "");

	my $url = sprintf("https://www.geni.com/api/profile/%s?%s&count=true%s",
			$api_action,
			$env{'all_of_geni'} ? "all=true" : "collaborators=true",
			$env{'yesterday'} ? "&since=yesterday" : "");

	my $json_page = getJSON($filename, $url, 0, 0);
	my $conflict_count = $json_page->{'count'};
	my $max_page = 0;

	# For some odd reason pending_merges are listed 20 per page while tree conflicts are listed 50 per page
	if ($env{'action'} eq "pending_merges") {
		$max_page = roundup($conflict_count/20);
	} else {
		$max_page = roundup($conflict_count/50);
	}
	printDebug($DBG_PROGRESS,
		sprintf("There are %d %s spread over %d pages\n",
			$conflict_count, $type, $max_page));

	if ($range_end > $max_page || !$range_end) {
		printDebug($DBG_PROGRESS, "Adjusting -re '$range_end' to the maximum page '$max_page'\n");
		$range_end = $max_page;
	}

	if (!$range_begin) {
		$range_begin = 1;
	}

	for (my $i = $range_begin; $i <= $range_end; $i++) {
		$range_begin = $i if (-e "$env{'datadir'}/$api_action\_$i.json");
	}

	if ($range_begin > $range_end) {
		printDebug($DBG_PROGRESS, "ERROR: -rb $range_begin is greater than -re '$range_end'\n");
		exit();
	}
	printDebug($DBG_PROGRESS, "Page Range $range_begin -> $range_end\n");

	return ($range_begin, $range_end);
}

sub apiURL($$) {
	my $api_action	= shift;
	my $page	= shift;

	# pass "only_ids=true" when they get the API fixed
	printf STDERR ("https://www.geni.com/api/profile/%s?%s&only_ids=true%s&page=%d\n",
			$api_action,
			$env{'all_of_geni'} ? "all=true" : "collaborators=true",
			$env{'yesterday'} ? "&since=yesterday" : "",
			$page);
	return sprintf ("https://www.geni.com/api/profile/%s?%s&only_ids=true%s&page=%d",
			$api_action,
			$env{'all_of_geni'} ? "all=true" : "collaborators=true",
			$env{'yesterday'} ? "&since=yesterday" : "",
			$page);
}

#
# Loop through every page of a JSON list and analyze each profile,
# merge, etc on each page. This can take days....
#
sub traverseJSONPages($$$$) {
	my $range_begin	= shift;
	my $range_end	= shift;
	my $type	= shift;
	my $focus_id	= shift;

	if ($focus_id) {
		printDebug($DBG_PROGRESS, "ERROR: focus_id is not supported via the API yet\n");
		return;
	}

	my $api_action;
	if ($type eq "PENDING_MERGES") {
		$api_action = "merges";

	} elsif ($type eq "TREE_CONFLICTS") {
		$api_action = "tree-conflicts";

	} elsif ($type eq "TREE_MATCHES") {
		$api_action = "tree-matches";

	} elsif ($type eq "DATA_CONFLICTS") {
		$api_action = "data-conflicts";

	} else {
		printDebug($DBG_PROGRESS, "ERROR: type '$type' is not supported\n");
		return;
	}

	my $range_begin_original = $range_begin;
	($range_begin, $range_end) = rangeBeginEnd($range_begin, $range_end, $type, $api_action);
	my $filename = "$env{'datadir'}/$api_action\_$range_begin\.json";
	my $url = apiURL($api_action, $range_begin);
	my $json_page = getJSON($filename, $url, 0, 0);
	if (!$json_page) {
		return 0;
	}

	my $next_url = "";
	while ($url ne "") {
		$url =~ /page=(\d+)/;
		my $page = $1;
		if ($page + 1 <= $range_end) {
			$next_url = apiURL($api_action, $page + 1);
		} else {
			$next_url = "";
		}
		$env{'log_file'} = "$env{'logdir'}/logfile_" . dateHourMinuteSecond() . "_page_$page\.html";
		write_file($env{'log_file'}, "<pre>", 0);

		my $loop_start_time = time();
		my $page_profile_count = 0;
		my $filename = "$env{'datadir'}/$api_action\_$page.json";
		my $json_page = getJSON($filename, $url, 0, 0);
		$url = $next_url;
		next if (!$json_page);

		foreach my $json_list_entry (@{$json_page->{'results'}}) {
			$env{'profiles'}++;
			$page_profile_count++;
			printDebug($DBG_PROGRESS, "Page $page/$range_end: Profile $page_profile_count: Overall Profile $env{'profiles'}");
		
			if ($type eq "PENDING_MERGES") {
				foreach my $private_ID (@{$json_list_entry->{'private'}}) {
					$private_ID =~ s/profile-//;
					checkPublic($private_ID);
				}

				my $left_id = $json_list_entry->{'profiles'}->[0];
				my $right_id = $json_list_entry->{'profiles'}->[1];
				$left_id =~ s/profile-//;
				$right_id =~ s/profile-//;
				analyzePendingMerge($left_id, $right_id);
			} elsif ($type eq "TREE_CONFLICTS") {
				printDebug($DBG_PROGRESS, "\n");
				my $conflict_type = $json_list_entry->{'issue_type'};
				my $profile_id = $json_list_entry->{'profile'};
				$profile_id =~ s/profile-//;

				if ($conflict_type eq "parent") {
			 		analyzeTreeConflict($profile_id, "parent");
			 		analyzeTreeConflict($profile_id, "siblings");
				} elsif ($conflict_type eq "partner") {
			 		analyzeTreeConflict($profile_id, "partner");
			 		analyzeTreeConflict($profile_id, "children");
				} else {
					printDebug($DBG_PROGRESS, "ERROR: Unknown tree conflict type '$conflict_type'\n");
					next;
				}
				analyzeNewTreeConflicts();
				unlink "$env{'datadir'}/$profile_id\.json" if ($env{'delete_files'});
				printDebug($DBG_PROGRESS, "\n\n");
			} elsif ($type eq "TREE_MATCHES") {
				analyzeTreeMatch(0);
			} elsif ($type eq "DATA_CONFLICTS") {
				analyzeDataConflict(0);
			}

			printDebug($DBG_NONE, "\n");
		}

		my $loop_run_time = time() - $loop_start_time;
		printDebug($DBG_NONE,
			sprintf("Run time for page $page: %02d:%02d:%02d\n",
				int($loop_run_time/3600),
				int(($loop_run_time % 3600) / 60),
			int($loop_run_time % 60)));
		printDebug($DBG_PROGRESS, "$env{'matches'} matches out of $env{'profiles'} profiles so far\n\n");
		loadCache();
	}

	printDebug($DBG_PROGRESS, "$env{'matches'} matches out of $env{'profiles'} profiles\n\n");

	if ($env{'loop'}) {
		system "chmod 755 $env{'datadir'}/*.json";
		print "unlink $env{'datadir'}/$api_action\_count.json\n";
		unlink("$env{'datadir'}/$api_action\_count.json");
		print "range_begin_original($range_begin_original), range_end($range_end)\n";

		for (my $i = $range_begin_original; $i <= $range_end; $i++) {
			unlink("$env{'datadir'}/$api_action\_$i.json");
			print "unlink $env{'datadir'}/$api_action\_$i.json\n";
		}
	}
}

sub validateProfileID($) {
	my $profile_id = shift;
	if (!$profile_id || $profile_id !~ /^\d+$/) {
		print STDERR "\nERROR: You must specify a profile ID, you entered '$profile_id'\n";
		exit();
	}
}

# Geni changed ID systems, use this to convert from old to new
sub convertGUIDToNodeID($) {
	my $guid = shift;

	my $filename = "$env{'datadir'}/$guid\.json";
	my $url = "https://www.geni.com/api/profile-G$guid";
	my $json_profile = getJSON($filename, $url, $guid, 0);
	return "" if (!$json_profile);

	if ($json_profile->{'id'} =~ /profile-(\d+)$/) {
		return $1;
	}

	return "";
}

sub main() {
	$env{'username'}	= "";
	$env{'password'}	= "";
	my $range_begin		= 0;
	my $range_end		= 0;
	my $left_id		= "";
	my $right_id		= "";
	my $run_from_cgi	= 0;

	#
	# Parse all command line arguements
	#
	for (my $i = 0; $i <= $#ARGV; $i++) {

		# Required
		if ($ARGV[$i] eq "-u" || $ARGV[$i] eq "-username") {
			$env{'username'} = $ARGV[++$i];

		} elsif ($ARGV[$i] eq "-p" || $ARGV[$i] eq "-password") {
			$env{'password'} = $ARGV[++$i];

		# At least of of these is required 
		} elsif ($ARGV[$i] eq "-pms" || $ARGV[$i] eq "-pending_merges") {
			$env{'action'} = "pending_merges";

		} elsif ($ARGV[$i] eq "-pmfg") {
			$env{'action'} = "pending_merges_family_group";
			$left_id = $ARGV[++$i];

		} elsif ($ARGV[$i] eq "-pm" || $ARGV[$i] eq "-pending_merge") {
			$left_id = $ARGV[++$i];
			$right_id = $ARGV[++$i];
			$env{'action'} = "pending_merge";

		} elsif ($ARGV[$i] eq "-tcs" || $ARGV[$i] eq "-tree_conflicts") {
			$env{'action'} = "tree_conflicts";

		} elsif ($ARGV[$i] eq "-tcr") {
			$env{'action'} = "tree_conflicts_recursive";
			$left_id = $ARGV[++$i];

		} elsif ($ARGV[$i] eq "-tc" || $ARGV[$i] eq "-tree_conflict") {
			$left_id = $ARGV[++$i];
			$env{'action'} = "tree_conflict";

		} elsif ($ARGV[$i] eq "-tms" || $ARGV[$i] eq "-tree_matches") {
			$env{'action'} = "tree_matches";

		} elsif ($ARGV[$i] eq "-tm" || $ARGV[$i] eq "-tree_match") {
			$env{'action'} = "tree_match";
			$left_id = $ARGV[++$i];

		} elsif ($ARGV[$i] eq "-dcs" || $ARGV[$i] eq "-data_conflicts") {
			$env{'action'} = "data_conflicts";

		} elsif ($ARGV[$i] eq "-dc" || $ARGV[$i] eq "-data_conflict") {
			$env{'action'} = "data_conflict";
			$left_id = $ARGV[++$i];

		} elsif ($ARGV[$i] eq "-stack") {
			$env{'action'} = "stack";
			$left_id = $ARGV[++$i];
			$right_id = $ARGV[++$i];

		# Optional
		} elsif ($ARGV[$i] eq "-all" || $ARGV[$i] eq "-all_of_geni") {
			$env{'all_of_geni'} = 1;

		} elsif ($ARGV[$i] eq "-y") {
			$env{'yesterday'} = 1;

		} elsif ($ARGV[$i] eq "-rb") {
			$range_begin = $ARGV[++$i];

		} elsif ($ARGV[$i] eq "-re") {
			$range_end = $ARGV[++$i];

		} elsif ($ARGV[$i] eq "-loop") {
			$env{'loop'} = 1;

		} elsif ($ARGV[$i] eq "-mlt" || $ARGV[$i] eq "-merge_little_trees") {
			$env{'merge_little_trees'} = 1;

		} elsif ($ARGV[$i] eq "-x") {
			$env{'delete'} = 1;

		} elsif ($ARGV[$i] eq "-h" || $ARGV[$i] eq "-help") {
			printHelp();

		# Developer options, these are not listed in the help menu
		} elsif ($ARGV[$i] eq "-api" || $ARGV[$i] eq "-api_get_limit") {
			$env{'get_limit'} = $ARGV[++$i];

		} elsif ($ARGV[$i] eq "-run_from_cgi") {
			$run_from_cgi = 1;

		} elsif ($ARGV[$i] eq "-focal") {
			$env{'action'} = "focal";
			$left_id = $ARGV[++$i];
			$right_id = $ARGV[++$i];

		} elsif ($ARGV[$i] eq "-cp" || $ARGV[$i] eq "-check_public") {
			$env{'action'} = "check_public";
			$left_id = $ARGV[++$i];

		} else { 
			printDebug($DBG_PROGRESS, "ERROR: '$ARGV[$i]' is not a supported arguement\n");
			printHelp();
		}
	}

	$env{'default_login'} 	= "default_login.txt";
	if ($env{'username'} eq "") {
		if (-e $env{'default_login'}) {
			open (INF, $env{'default_login'}) or die("ERROR: can't open $env{'default_login'}");
			$env{'username'} = <INF>;
			chomp($env{'username'});
			$env{'password'} = <INF>;
			chomp($env{'password'});
			close INF;
		} else {
			print "username: ";
			$env{'username'} = <STDIN>;
		}
	}

	$env{'username'}		=~ /^(.*)\@/;
	$env{'username_short'}		= $1;
	$env{'datadir'} 		= "script_data";
	$env{'logdir'}			= "logs";
	$env{'merge_log_file'}		= "merge_log.html";
	$env{'merge_fail_file'}		= "merge_fail.html";
	$env{'ugly_file'}		= "ugly_profiles.html";
	$env{'cache_merge_request'}	= "cache_merge_request.txt";
	$env{'cache_merge_fail'}	= "cache_merge_fail.txt";
	$env{'cache_no_match'}		= "cache_no_match.txt";
	$env{'cache_name_mismatch'}	= "cache_name_mismatch.txt";
	$env{'cache_private_profiles'}	= "cache_private_profiles.txt";
	$env{'log_file'}		= "$env{'logdir'}/logfile_" . dateHourMinuteSecond() . ".html";

	if ($run_from_cgi) {
		$env{'home_dir'}		= "/home/geni/www";
		$env{'user_home_dir'}		= "$env{'home_dir'}/$env{'username_short'}";
		$env{'datadir'} 		= "$env{'user_home_dir'}/script_data";
		$env{'logdir'}			= "$env{'user_home_dir'}/logs";
		$env{'merge_log_file'}		= "$env{'home_dir'}/merge_log.html";
		$env{'merge_fail_file'}		= "$env{'home_dir'}/merge_fail.html";
		$env{'ugly_file'}		= "$env{'home_dir'}/ugly_profiles.html";
		$env{'cache_merge_request'}	= "$env{'home_dir'}/cache_merge_request.txt";
		$env{'cache_merge_fail'}	= "$env{'home_dir'}/cache_merge_fail.txt";
		$env{'cache_no_match'}		= "$env{'home_dir'}/cache_no_match.txt";
		$env{'cache_name_mismatch'}	= "$env{'home_dir'}/cache_name_mismatch.txt";
		$env{'cache_private_profiles'}	= "$env{'home_dir'}/cache_private_profiles.txt";
		system "rm -rf $env{'datadir'}/*";
		system "rm -rf $env{'logdir'}/*";
		(mkdir $env{'home_dir'}, 0755) if !(-e $env{'home_dir'});
		(mkdir $env{'user_home_dir'}, 0755) if !($env{'user_home_dir'} && -e $env{'user_home_dir'});
	}elsif($env{'delete'}){
		system "rm -rf $env{'datadir'}/*";
	}

	(mkdir $env{'datadir'}, 0755) if !(-e $env{'datadir'});
	(mkdir $env{'logdir'}, 0755) if !(-e $env{'logdir'});
	write_file($env{'log_file'}, "<html><head><meta http-equiv=\"refresh\" content=\"60\"></head><pre>\n", 0);
	write_file($env{'merge_log_file'}, "<pre>", 0) if !(-e $env{'merge_log_file'});
	write_file($env{'merge_fail_file'}, "<html><head><title>geni-automerge Failed Merges</title></head><pre>", 0) if !(-e $env{'merge_fail_file'});
	write_file($env{'ugly_file'}, "<pre>\n", 0) if !(-e $env{'ugly_file'});
	loadCache();

	if ($env{'password'} eq "") {
		if ($run_from_cgi) {
			my $password_file = "/home/geni/www/cgi-bin/geni-automerge/passwords/$env{'username'}\.txt";
			open (INF,$password_file) or die("can't open /home/geni/www/cgi-bin/geni-automerge/passwords/$env{'username'}\.txt");
			$env{'password'} = <INF>;
			close INF;
		} else {
			print "password: ";
			$env{'password'} = <STDIN>;
		}
	}

	if ($env{'action'} eq "pending_merges") {
		do {
			traverseJSONPages($range_begin, $range_end, "PENDING_MERGES", 0);
		} while ($env{'loop'});

	} elsif ($env{'action'} eq "pending_merges_family_group") {
		traverseJSONPages($range_begin, $range_end, "PENDING_CONFLICTS", $left_id);

	} elsif ($env{'action'} eq "pending_merge") {
		if (!$left_id || !$right_id) {
			print STDERR "\nERROR: You must specify two profile IDs, you only specified one\n";
			exit();
		}
		$left_id = convertGUIDToNodeID($left_id);
		$right_id = convertGUIDToNodeID($right_id);
		validateProfileID($left_id);
		validateProfileID($right_id);
		analyzePendingMerge($left_id, $right_id);

	} elsif ($env{'action'} eq "tree_conflicts") {
		do {
			traverseJSONPages($range_begin, $range_end, "TREE_CONFLICTS", 0);
		} while ($env{'loop'});

	} elsif ($env{'action'} eq "tree_conflicts_recursive") {
		$left_id = convertGUIDToNodeID($left_id);
		validateProfileID($left_id);
		analyzeTreeConflictRecursive($left_id);

	} elsif ($env{'action'} eq "tree_conflict") {
		$left_id = convertGUIDToNodeID($left_id);
		validateProfileID($left_id);
		analyzeTreeConflict($left_id, "parent");
		analyzeTreeConflict($left_id, "siblings");
		analyzeTreeConflict($left_id, "partner");
		analyzeTreeConflict($left_id, "children");
		unlink "$env{'datadir'}/$left_id\.json" if ($env{'delete_files'});

	} elsif ($env{'action'} eq "tree_matches") {
		printDebug($DBG_PROGRESS, "NOTE: The -all option is not supported for Tree Matches\n") if $env{'all_of_geni'};
		$env{'all_of_geni'} = 0;
		do {
			traverseJSONPages($range_begin, $range_end, "TREE_MATCHES", 0);
		} while ($env{'loop'});

	} elsif ($env{'action'} eq "tree_match") {
		validateProfileID($left_id);
		analyzeTreeMatch($left_id);

	} elsif ($env{'action'} eq "stack") {
		$left_id = convertGUIDToNodeID($left_id);
		$right_id = convertGUIDToNodeID($right_id);
		validateProfileID($left_id);
		validateProfileID($right_id);
		stackProfiles($left_id, $right_id);

	} elsif ($env{'action'} eq "data_conflicts") {
		do {
			traverseJSONPages($range_begin, $range_end, "DATA_CONFLICTS", 0);
		} while ($env{'loop'});

	} elsif ($env{'action'} eq "data_conflict") {
		validateProfileID($left_id);
		analyzeDataConflict($left_id);

	} elsif ($env{'action'} eq "focal") {
		$left_id = convertGUIDToNodeID($left_id);
		$right_id = convertGUIDToNodeID($right_id);
		validateProfileID($left_id);
		validateProfileID($right_id);
		stackProfiles($left_id, $right_id);
		analyzeTreeConflict($left_id, "parent");
		analyzeTreeConflict($left_id, "siblings");
		analyzeTreeConflict($left_id, "partner");
		analyzeTreeConflict($left_id, "children");
		unlink "$env{'datadir'}/$left_id\.json" if ($env{'delete_files'});
		analyzeTreeConflictRecursive($left_id);

	} elsif ($env{'action'} eq "check_public") {
		validateProfileID($left_id);
		checkPublic($left_id);

	}

	geniLogout();
	my $end_time = time();
	my $run_time = $end_time - $env{'start_time'};
	printDebug($DBG_NONE,
		sprintf("Total running time: %02d:%02d:%02d\n",
			int($run_time/3600),
			int(($run_time % 3600) / 60),
			int($run_time % 60)));
	write_file($env{'log_file'}, "\n\nFINISHED!</html></pre>\n", 1);
	write_file($env{'merge_fail_file'}, "</html></pre>\n", 1);
}

1;

__END__
46,805,758 big tree profiles on 10/29/2010

TODO
- improve circa range for older profiles
- for tree conflicts run check_public if needed.  Note we need an API change from Amos before we can do this
- test half-siblings once they fix this in the API
- 6000000007224268070 vs 6000000003243493709 has a profile with the birthdate as part of the name
  We could fix this.
	-cleanupName  pre-clean: Samuel Seabury b. 10 Dec 1640
	-cleanupName post-clean: samuel seabury b dec 1640
