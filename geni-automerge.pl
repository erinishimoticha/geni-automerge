#!/usr/bin/perl

use strict;
use WWW::Mechanize;
use HTTP::Cookies;
use Class::Struct;
use Time::HiRes;
use JSON;
# http://search.cpan.org/~maurice/Text-DoubleMetaphone-0.07/DoubleMetaphone.pm
use Text::DoubleMetaphone qw( double_metaphone );
use HTTP::Response;

# globals and constants
my (%env, %debug, %blacklist_managers, @get_history);
my $m = WWW::Mechanize->new(autocheck => 0);
my $DBG_NONE			= "DBG_NONE"; # Normal output
my $DBG_PROGRESS		= "DBG_PROGRESS";
my $DBG_URLS			= "DBG_URLS";
my $DBG_IO			= "DBG_IO";
my $DBG_NAMES			= "DBG_NAMES";
my $DBG_JSON			= "DBG_JSON";
my $DBG_MATCH_DATE		= "DBG_MATCH_DATE";
my $DBG_MATCH_BASIC		= "DBG_MATCH_BASIC";

init();
main();

sub init(){
	# configuration
	$env{'circa_range'}		= 5;
	$env{'get_timeframe'}		= 10;
	$env{'get_limit'}		= 18; # Amos has the limit set to 20 so we'll use 18 to have some breathing room
	$env{'action'}			= "pending_merges";

	# environment
	$env{'start_time'}		= time();
	$env{'logged_in'}		= 0;
	$env{'matches'} 		= 0;
	$env{'profiles'}		= 0;
	$env{'merge_little_trees'}	= 0;
	$env{'all_of_geni'}		= 0;
	$env{'loop'}			= 0;
	$env{'direction'}		= "asc"; # Must be asc or desc
	$env{'delete_files'}		= 1;

	$debug{"file_" . $DBG_NONE}		= 1;
	$debug{"file_" . $DBG_PROGRESS}		= 1;
	$debug{"file_" . $DBG_IO}		= 0;
	$debug{"file_" . $DBG_URLS}		= 1;
	$debug{"file_" . $DBG_NAMES}		= 0;
	$debug{"file_" . $DBG_JSON}		= 0;
	$debug{"file_" . $DBG_MATCH_BASIC}	= 1;
	$debug{"file_" . $DBG_MATCH_DATE}	= 1;
	$debug{"console_" . $DBG_NONE}		= 0;
	$debug{"console_" . $DBG_PROGRESS}	= 1;
	$debug{"console_" . $DBG_IO}		= 0;
	$debug{"console_" . $DBG_URLS}		= 0;
	$debug{"console_" . $DBG_NAMES}		= 0;
	$debug{"console_" . $DBG_JSON}		= 0;
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
#	print STDERR "-tcfg X: Tree Conflicts - Analyze for the family-group of profile ID X\n";
#	print STDERR "-tms   : Tree Matches   - Analyze your entire list\n";
#	print STDERR "-tm X  : Tree Matches   - Analyze profile ID X\n";
#	print STDERR "-dcs   : Data Conflicts - Analyze your entire list\n";
#	print STDERR "-dc X  : Data Conflicts - Analyze profile ID X\n";
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
	open(OUT,"$append$file") || gracefulExit("\n\nERROR: write_file could not open '$file'\n\n");
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

	# Some profiles are private and we cannot access them
	if ($json_data =~ /Access denied/i || $json_data =~ /SecurityError/i) {
		printDebug($DBG_NONE, "NOTICE: Private profile in '$filename'\n");
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
			printDebug($DBG_PROGRESS, "ERROR: sleep_length was 0.  Using $env{'get_timeframe'} instead\n");
			$sleep_length = $env{'get_timeframe'};
		}
		printDebug($DBG_PROGRESS,
			sprintf("%d gets() in the past %d seconds....sleeping for %d second%s\n",
				$gets_in_api_timeframe, $env{'get_timeframe'}, $sleep_length, $sleep_length > 1 ? "s" : ""));
		sleep($sleep_length);
	}
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
	$m->get($url);
	write_file($filename, $m->content(), 0);
	updateGetHistory();
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


	# Treat the I in "Edgar I of England" differently from "Robert I. Smith"
	# We want to remember the I/V/X that are abbreviations but remove the others.
	$name =~ s/I\./ INITIAL_I /g;
	$name =~ s/V\./ INITIAL_V /g;
	$name =~ s/X\./ INITIAL_X /g;

	# Remove punctuation
	$name =~ s/ d\'/ /g;
	$name =~ s/\./ /g;
	$name =~ s/\?/ /g;
	$name =~ s/\*/ /g;
	$name =~ s/\~/ /g;
	$name =~ s/\:/ /g;
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
				"capt", "captain", "chief justice", "honorable", "hon", "col", "dr", "colonel",
				"i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x", "xi", "xii", "xiii",
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

	$name =~ s/ INITIAL_I / I /g;
	$name =~ s/ INITIAL_V / V /g;
	$name =~ s/ INITIAL_X / X /g;

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

	# This can only happen if we're looking at a profile with multiple middle names.
	# If that is the case then don't consider "R. vs. Robert" a match.  The reason
	# being there could be 5 middle names and it would be too easy for one of them 
	# to match an initial.
	if ($left_name =~ /\s/ || $right_name =~ /\s/) {
		$compare_initials = 0;
	}

	# Again, this only happens for multiple middle names.  We compare all the middle
	# names from the left profile with the middle names from the right profile. If
	# one of them matches return true. This is designed for cases like this:
	# 'sarah dabney taylor (strother)' vs. right 'sarah pannill dabney taylor (strother)'
	foreach my $left_name_component (split(/\s/, $left_name)) {
		foreach my $right_name_component (split(/\s/, $right_name)) {
			return 1 if $left_name_component eq $right_name_component;
			return 1 if $compare_initials && initialVsWholeMatch($left_name_component, $right_name_component);
			return 1 if doubleMetaphoneCompare($left_name_component, $right_name_component);
		}
	}
	return 0;
}

# Return TRUE if they match
sub compareNames($$$$) {
	my $gender	= shift;
	my $left_name	= shift;
	my $right_name	= shift;
	my $debug	= shift;

	if ($left_name eq $right_name) {
		printDebug($DBG_NONE,
			sprintf("MATCH Whole Name: left '%s' vs. right '%s'\n",
				$left_name,
				$right_name)) if $debug;
		return 1;
	}

	# It one name is blank then be conservative and return false
	return 0 if (!$left_name || !$right_name);

	my $left_name_first	= "";
	my $left_name_middle	= "";
	my $left_name_last	= "";
	my $left_name_maiden	= "";

	if ($left_name =~ / \((.*)\)$/) {
		$left_name_maiden = $1;
		$left_name = $`;
	}

	if ($left_name =~ /^(.*?)\s(.*)\s(.*?)$/) {
		$left_name_first = $1;
		$left_name_middle = $2;
		$left_name_last= $3;
	} elsif ($left_name =~ /^(.*?)\s(.*?)$/) {
		$left_name_first = $1;
		$left_name_last= $2;
	} elsif ($left_name =~ /^(.*?)$/) {
		$left_name_first = $1;
	# This should not happen
	} else {
		$left_name_first = $left_name;
	}

	my $right_name_first	= "";
	my $right_name_middle	= "";
	my $right_name_last	= "";
	my $right_name_maiden	= "";

	if ($right_name =~ / \((.*)\)$/) {
		$right_name_maiden = $1;
		$right_name = $`;
	}

	if ($right_name =~ /^(.*?)\s(.*)\s(.*?)$/) {
		$right_name_first = $1;
		$right_name_middle = $2;
		$right_name_last= $3;
	} elsif ($right_name =~ /^(.*?)\s(.*?)$/) {
		$right_name_first = $1;
		$right_name_last= $2;
	} elsif ($right_name =~ /^(.*?)$/) {
		$right_name_first = $1;
	# This should not happen
	} else {
		$right_name_first = $right_name;
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

	printDebug($DBG_NONE,
		sprintf("%sMATCH First Name: left '%s' vs. right '%s'\n",
			($first_name_matches) ? "" : "NO_",
			$left_name_first,
			$right_name_first)) if $debug;
	printDebug($DBG_NONE,
		sprintf("%sMATCH Middle Name: left '%s' vs. right '%s'\n",
			($middle_name_matches) ? "" : "NO_",
			$left_name_middle,
			$right_name_middle)) if $debug;

	if ($gender eq "female") {
		printDebug($DBG_NONE,
			sprintf("%sMATCH Last Name: left '%s (%s)' vs. right '%s (%s)'\n",
				($last_name_matches) ? "" : "NO_",
				$left_name_last,
				$left_name_maiden,
				$right_name_last,
				$right_name_maiden)) if $debug;
	} else {
		printDebug($DBG_NONE,
			sprintf("%sMATCH Last Name: left '%s' vs. right '%s'\n",
				($last_name_matches) ? "" : "NO_",
				$left_name_last,
				$right_name_last)) if $debug;
	}

	# This should never happen but just to be safe return false if everything is blank
	if (!$left_name_first && !$left_name_middle && !$left_name_last && !$left_name_maiden &&
	    !$right_name_first && !$right_name_middle && !$right_name_last && !$right_name_maiden) {
		printDebug($DBG_PROGRESS, "ERROR: compareNames all names were blank\n");
		return 0;
	}

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
			sprintf("NO_MATCH: gender '%s' ne '%s'\n",
				$left_profile->gender,
				$right_profile->gender));
		return 0;
	}

	if (!compareNames($left_profile->gender, $left_name, $right_name, 1)) {
		printDebug($DBG_MATCH_BASIC,
			sprintf("NO_MATCH: name '%s' ne '%s'\n",
				$left_name,
				$right_name));
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

	if ($left_partners ne $right_partners) { 
		foreach my $person (split(/:/, $left_partners)) {
			foreach my $person2 (split(/:/, $right_partners)) {
				if (compareNames($gender, $person, $person2, 1)) {
					printDebug($DBG_MATCH_BASIC, "One of the $partner_type is a match.\n");
					return 1;
				}
			}
		}

		printDebug($DBG_MATCH_BASIC, "NO_MATCH: $partner_type do not match\n");

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
	my $value_array = shift;
	my $value_to_add= shift;

	# We're storing profiles in the array
	if ($value_to_add =~ /^\d+/) {
		foreach my $profile_id (@$value_array) {
			return if ($profile_id eq $value_to_add);
		}

	# We're storing names in the array
	} else {
		foreach my $name (@$value_array) {
			return if compareNames($gender, $name, $value_to_add, 0);
		}
	}

	push @$value_array, $value_to_add;
}

sub mergeURLHTML($$) {
	my $id1			= shift;
	my $id2			= shift;
	return "<a href=\"http://www.geni.com/merge/compare/$id1?return=merge_center&to=$id2\">http://www.geni.com/merge/compare/$id1?return=merge_center&to=$id2</a>";
}

sub compareProfiles($$) {
	my $id1			= shift;
	my $id2			= shift;
	my $id1_url = "<a href=\"http://www.geni.com/people/id/$id1\">$id1</a>";
	my $id2_url = "<a href=\"http://www.geni.com/people/id/$id2\">$id2</a>";

	my $profiles_url = "https://www.geni.com/api/profiles/compare/$id1,$id2";
	my $filename = sprintf("$env{'datadir'}/%s-%s.json", $id1, $id2);
	my $json_text = getJSON($filename, $profiles_url);
	return 0 if (!$json_text);
	printDebug($DBG_NONE, "\n\nComparing profile $id1_url to profile $id2_url\n");
	printDebug($DBG_NONE, "Merge URL: " . mergeURLHTML($id1, $id2) . "\n");

	my $left_profile = new profile;
	my $right_profile= new profile;
	my $geni_profile = $left_profile;
	foreach my $json_profile (@{$json_text->{'results'}}) {

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
				printDebug($DBG_NONE,
					sprintf("NO_MATCH: %s is managed by blacklist user %s\n",
						($geni_profile == $left_profile) ? $id1_url : $id2_url,
						"<a href=\"http://www.geni.com/people/id/$profile_id/\">$profile_id</a>\n"));
				unlink $filename if $env{'delete_files'};
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
		$geni_profile->id($json_profile->{'focus'}->{'id'});
		
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
sub updateGetHistory() {
	(my $time_sec, my $time_usec) = Time::HiRes::gettimeofday();
	push @get_history, "$time_sec.$time_usec\n";
}

sub mergeProfiles($$$$) {
	my $merge_url_api	= shift;
	my $id1			= shift;
	my $id2			= shift;
	my $desc		= shift;
	my $id1_url = "<a href=\"http://www.geni.com/people/id/$id1\">$id1</a>";
	my $id2_url = "<a href=\"http://www.geni.com/people/id/$id2\">$id2</a>";

	(my $sec, my $min, my $hour, my $mday, my $mon, my $year, my $wday, my $yday, my $isdst) = localtime(time);
	write_file($env{'merge_log_file'}, sprintf("%4d-%02d-%02d %02d:%02d:%02d :: %s :: %s :: Merged %s with %s\n",
 			$year+1900, $mon+1, $mday, $hour, $min, $sec,
			$env{'username'}, $desc, $id1_url, $id2_url), 1);
	$env{'matches'}++;
	geniLogin() if !$env{'logged_in'};
	printDebug($DBG_PROGRESS, "MERGING: $id1 and $id2\n");
	sleepIfNeeded();
	$m->post($merge_url_api);
	updateGetHistory();
}

sub compareAllProfiles($$) {
	my $text		= shift;
	my $profiles_array_ptr	= shift;
	my @profiles_array = @$profiles_array_ptr;
	my $profile_count = 0;
	my $match_count = 0;

	for (my $i = 0; $i <= $#profiles_array; $i++) {
		(my $i_id, my $i_name, my $gender) = split(/:/, $profiles_array[$i]);

		for (my $j = $i + 1; $j <= $#profiles_array; $j++) {
			(my $j_id, my $j_name, my $gender) = split(/:/, $profiles_array[$j]);
			if (compareNames($gender, $i_name, $j_name, 0)) {
				if (compareProfiles($i_id, $j_id)) {
					printDebug($DBG_PROGRESS, "TREE_CONFLICT_COMPARE: $text\[$i] $i_name vs. $text\[$j] $j_name - MATCH\n");
					mergeProfiles("https://www.geni.com/api/profiles/merge/$i_id,$j_id", $i_id, $j_id, "TREE_CONFLICT");
					$match_count++;
				} else {
					printDebug($DBG_PROGRESS, "TREE_CONFLICT_COMPARE: $text\[$i] $i_name vs. $text\[$j] $j_name - NO_MATCH\n");
				}
			} else {
				printDebug($DBG_PROGRESS, "TREE_CONFLICT_COMPARE: $text\[$i] $i_name vs. $text\[$j] $j_name - NAME_MISMATCH\n");
			}
			$profile_count++;
		}
	}

	return ($profile_count, $match_count);
}

# todo: test this on 4354532190790066194 when Amos fixes the API
sub checkPublic($) {
	my $profile_id	= shift;
	return if (!$profile_id);
	geniLogin() if !$env{'logged_in'};

	my $result = new HTTP::Response;
	my $url = "https://www.geni.com/api/profiles/check_public/$profile_id";
	$result = $m->post($url);
	if ($result->is_success) {
		printf("checkPublic(IS_SUCCESS): %s\n", $result->decoded_content);
	} else {
		printf("checkPublic: %s\n", $result->status_line);
	}
}

sub analyzeTreeConflict($$) {
	my $profile_id	= shift;
	my $issue_type	= shift;
	
	if ($profile_id =~ /profiles\/(\d+)/) {
		$profile_id = $1;
	}

	printDebug($DBG_PROGRESS, "\nTree Conflict analyze for '$profile_id', type '$issue_type'\n");

	my $filename = "$env{'datadir'}/$profile_id\.json";
	my $json_text = getJSON($filename, "https://www.geni.com/api/profiles/immediate_family/$profile_id");
	return 0 if (!$json_text);

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
			my $name_first = $json_profile->{'nodes'}->{$j}->{'first_name'};
			my $name_middle = $json_profile->{'nodes'}->{$j}->{'middle_name'};
			my $name_last = $json_profile->{'nodes'}->{$j}->{'last_name'};
			my $name_maiden = $json_profile->{'nodes'}->{$j}->{'maiden_name'};
			my $name = cleanupName($name_first, $name_middle, $name_last, $name_maiden);
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
						avoidDuplicatesPush("", \@fathers, "$id:$name:$gender") if ($issue_type eq "parent");
					} elsif ($gender eq "female") {
						avoidDuplicatesPush("", \@mothers, "$id:$name:$gender") if ($issue_type eq "parent");
					}
				} elsif ($partner_type eq "spouses") {
					avoidDuplicatesPush("", \@spouses, "$id:$name:$gender") if ($issue_type eq "partner");
				}

			} elsif ($rel eq "child") {

				if ($partner_type eq "parents") {
					if ($gender eq "male") {
						avoidDuplicatesPush("", \@brothers, "$id:$name:$gender") if ($issue_type eq "siblings");
					} elsif ($gender eq "female") {
						avoidDuplicatesPush("", \@sisters, "$id:$name:$gender") if ($issue_type eq "siblings");
					}
				} elsif ($partner_type eq "spouses") {
					if ($gender eq "male") {
						avoidDuplicatesPush("", \@sons, "$id:$name:$gender") if ($issue_type eq "children");
					} elsif ($gender eq "female") {
						avoidDuplicatesPush("", \@daughters, "$id:$name:$gender") if ($issue_type eq "children");
					}
				}

			# A "hidden_child" is just a placeholder profile and can be ignored
			} elsif ($rel eq "hidden_child") {
			} else {
				printDebug($DBG_NONE, "ERROR: unknown rel type '$rel'\n");
			}
		}
	}

	my $profile_count = 0;
	my $match_count = 0;
	my $a, my $b;
	$env{'circa_range'} = 5;
	($a, $b) = compareAllProfiles("Father", \@fathers); $profile_count += $a; $match_count += $b;
	($a, $b) = compareAllProfiles("Mother", \@mothers); $profile_count += $a; $match_count += $b;
	($a, $b) = compareAllProfiles("Spouse", \@spouses); $profile_count += $a; $match_count += $b;

	# todo: need a better way to handle this if the profiles we're comparing have spouses.
	# We could go back to +- 5 for those cases.
	$env{'circa_range'} = 1;
	($a, $b) = compareAllProfiles("Sons", \@sons); $profile_count += $a; $match_count += $b;
	($a, $b) = compareAllProfiles("Daughters", \@daughters); $profile_count += $a; $match_count += $b;
	($a, $b) = compareAllProfiles("Brothers", \@brothers); $profile_count += $a; $match_count += $b;
	($a, $b) = compareAllProfiles("Sisters", \@sisters); $profile_count += $a; $match_count += $b;
	$env{'circa_range'} = 5;
	printDebug($DBG_PROGRESS, "Matched $match_count/$profile_count\n");

	unlink $filename if $env{'delete_files'};
}

sub analyzePendingMerge($$) {
	my $id1			= shift;
	my $id2			= shift;

	if (compareProfiles($id1, $id2)) {
		mergeProfiles("https://www.geni.com/api/profiles/merge/$id1,$id2", $id1, $id2, "PENDING_MERGE");
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
	my $primary_url = "<a href=\"http://www.geni.com/people/id/$primary_id\">$primary_id</a>";
	$IDs_to_stack =~ s/ //g;
	foreach my $id (split(/,/, $IDs_to_stack)) {
		if ($id !~ /^\d+$/) {
			printDebug($DBG_PROGRESS, "ERROR: '$id' is not a valid profile ID\n");
		}
		my $id_url = "<a href=\"http://www.geni.com/people/id/$id\">$id</a>";
		printDebug($DBG_PROGRESS, "\nStacking Primary $primary_id: Stacking Secondary $id\n");
		printDebug($DBG_NONE, "\nStacking Primary $primary_url: Stacking Secondary $id_url\n");
		mergeProfiles("https://www.geni.com/api/profiles/merge/$primary_id,$id", $primary_id, $id, "STACKING_MERGE");
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
	my $url = sprintf("https://www.geni.com/api/profiles/%s?collaborators=true&count=true%s",
			$api_action,
			$env{'all_of_geni'} ? "&all=true" : "");

	my $json_page = getJSON($filename, $url);
	my $conflict_count = $json_page->{'count'};
	my $max_page = roundup($conflict_count/50);
	printDebug($DBG_PROGRESS,
		sprintf("There are %d %s spread over %d pages\n",
			$conflict_count, $type, $max_page));

	if ($range_end > $max_page || !$range_end) {
		printDebug($DBG_PROGRESS, "Adjusting -re '$range_end' to the maximum page '$max_page'\n");
		$range_end = $max_page;
	}

	for (my $i = $range_begin; $i <= $range_end; $i++) {
		$range_begin = $i if (-e "$env{'datadir'}/$api_action\_$i.json");
	}

	if (!$range_begin) {
		$range_begin = 1;
	}

	if ($range_begin > $range_end) {
		printDebug($DBG_PROGRESS, "ERROR: -rb $range_begin is greater than -re '$range_end'\n");
		exit();
	}
	printDebug($DBG_PROGRESS, "Page Range $range_begin -> $range_end\n");

	return ($range_begin, $range_end);
}

sub getJSON ($$) {
	my $filename	= shift;
	my $url		= shift;

	getPage($filename, $url);
	if (jsonSanityCheck($filename) == 0) {
		unlink $filename if $env{'delete_files'};
		return 0;
	}
	open (INF,$filename);
	my $json_data = <INF>;
	my $json = new JSON;
	my $json_structure = $json->allow_nonref->relaxed->decode($json_data);
	close INF;

	printDebug($DBG_JSON, sprintf ("Pretty JSON:\n%s", $json->pretty->encode($json_structure))); 
	return $json_structure;
}

sub apiURL($$$) {
	my $api_action	= shift;
	my $page	= shift;
	my $focus_id	= shift;
	return sprintf("https://www.geni.com/api/profiles/%s?%s&order=last_modified_at&direction=%s&page=%s%s",
			$api_action,
			$focus_id ? "focus_id=$focus_id" : "collaborators=true",
			$env{'direction'},
			$page,
			$env{'all_of_geni'} ? "&all=true" : "");
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
		$api_action = "tree_conflicts";

	} elsif ($type eq "TREE_MATCHES") {
		$api_action = "tree_matches";

	} elsif ($type eq "DATA_CONFLICTS") {
		$api_action = "data_conflicts";

	} else {
		printDebug($DBG_PROGRESS, "ERROR: type '$type' is not supported\n");
		return;
	}

	($range_begin, $range_end) = rangeBeginEnd($range_begin, $range_end, $type, $api_action);
	my $filename = "$env{'datadir'}/$api_action\_$range_end\.json";
	my $url = apiURL($api_action, $range_end, $focus_id);
	my $json_page = getJSON($filename, $url);
	return 0 if (!$json_page);

	my $next_url = "";
	while ($url ne "") {
		$url =~ /page=(\d+)/;
		my $page = $1;
		if ($page - 1 >= $range_begin) {
			$next_url = apiURL($api_action, $page - 1, $focus_id);
		} else {
			$next_url = "";
		}
		$env{'log_file'} = "$env{'logdir'}/logfile_" . dateHourMinuteSecond() . "_page_$page\.html";
		write_file($env{'log_file'}, "<pre>", 0);

		my $loop_start_time = time();
		my $page_profile_count = 0;
		my $filename = "$env{'datadir'}/$api_action\_$page.json";
		my $json_page = getJSON($filename, $url);
		$url = $next_url;
		next if (!$json_page);

		foreach my $json_list_entry (@{$json_page->{'results'}}) {
			$env{'profiles'}++;
			$page_profile_count++;
			printDebug($DBG_PROGRESS, "Page $page/$range_end: Profile $page_profile_count: Overall Profile $env{'profiles'}\n");
		
			if ($type eq "PENDING_MERGES") {
				if ($json_list_entry->{'profiles'} =~ /\/(\d+),(\d+)$/) {
					analyzePendingMerge($1, $2);
				}
			} elsif ($type eq "TREE_CONFLICTS") {
				my $conflict_type = $json_list_entry->{'issue_type'};
				if ($conflict_type eq "parent") {
			 		analyzeTreeConflict($json_list_entry->{'profile'}, "parent");
			 		analyzeTreeConflict($json_list_entry->{'profile'}, "siblings");
				} elsif ($conflict_type eq "partner") {
			 		analyzeTreeConflict($json_list_entry->{'profile'}, "partner");
			 		analyzeTreeConflict($json_list_entry->{'profile'}, "children");
				} else {
					printDebug($DBG_PROGRESS, "ERROR: Unknown tree conflict type '$conflict_type'\n");
				}
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
		printDebug($DBG_PROGRESS, "$env{'matches'} matches out of $env{'profiles'} profiles so far\n");
	}

	printDebug($DBG_PROGRESS, "$env{'matches'} matches out of $env{'profiles'} profiles\n");
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
	push @date_tests, "c. 1905:1900:1";
	push @date_tests, "c. 1906:1900:0";
	push @date_tests, "1/1/1900:1901:0";
	push @date_tests, "c. 1/15/1785:1787:1";

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
		my $result = compareNames($gender, $left_name, $right_name, 1);
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
}

sub validateProfileID($) {
	my $profile_id = shift;
	if (!$profile_id || $profile_id !~ /^\d+$/) {
		print STDERR "\nERROR: You must specify a profile ID, you entered '$profile_id'\n";
		exit();
	}
}

sub main() {
	$env{'username'}	= "";
	$env{'password'}	= "";
	my $range_begin		= 0;
	my $range_end		= 0;
	my $left_id		= 0;
	my $right_id		= 0;
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

		} elsif ($ARGV[$i] eq "-tcfg") {
			$env{'action'} = "tree_conflicts_family_group";
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
		} elsif ($ARGV[$i] eq "-api_get_timeframe") {
			$env{'get_timeframe'} = $ARGV[++$i];

		} elsif ($ARGV[$i] eq "-api_get_limit") {
			$env{'get_limit'} = $ARGV[++$i];

		} elsif ($ARGV[$i] eq "-t" || $ARGV[$i] eq "-test") {
			$env{'action'} = "test";

		} elsif ($ARGV[$i] eq "-run_from_cgi") {
			$run_from_cgi = 1;

		# This is used if you want to loop through the most recent merges over and over.
		# So "-loop -desc -rb 1 -re 50" will loop through the first 50 pages of merge
		# issues over and over again.  These are likely to be merge issues from the past
		# 48 hours or so.
		} elsif ($ARGV[$i] eq "-desc") {
			$env{'direction'} = "desc";

		} elsif ($ARGV[$i] eq "-cp" || $ARGV[$i] eq "-check_public") {
			$env{'action'} = "check_public";
			$left_id = $ARGV[++$i];

		} else { 
			printDebug($DBG_PROGRESS, "ERROR: '$ARGV[$i]' is not a supported arguement\n");
			printHelp();
		}
	}

	if ($env{'username'} eq "") {
		print "username: ";
		$env{'username'} = <STDIN>;
	}

	$env{'username'}	=~ /^(.*)\@/;
	$env{'username_short'}	= $1;
	$env{'datadir'} 	= "script_data";
	$env{'logdir'}		= "logs";
	$env{'merge_log_file'}	= "merge_log.html";
	$env{'log_file'}	= "$env{'logdir'}/logfile_" . dateHourMinuteSecond() . ".html";

	if ($run_from_cgi) {
		$env{'home_dir'}	= "/home/geni/www";
		$env{'user_home_dir'}	= "$env{'home_dir'}/$env{'username_short'}";
		$env{'datadir'} 	= "$env{'user_home_dir'}/script_data";
		$env{'logdir'}		= "$env{'user_home_dir'}/logs";
		$env{'merge_log_file'}	= "$env{'home_dir'}/merge_log.html";
		system "rm -rf $env{'datadir'}/*";
		system "rm -rf $env{'logdir'}/*";
		(mkdir $env{'home_dir'}, 0755) if !(-e $env{'home_dir'});
		(mkdir $env{'user_home_dir'}, 0755) if !($env{'user_home_dir'} && -e $env{'user_home_dir'});
	}elsif($env{'delete'}){
		system "rm -rf $env{'datadir'}/*";
	}

	(mkdir $env{'datadir'}, 0755) if !(-e $env{'datadir'});
	(mkdir $env{'logdir'}, 0755) if !(-e $env{'logdir'});
	write_file($env{'log_file'}, "<pre>", 0);

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
			system "rm -rf $env{'datadir'}/*" if ($env{'loop'});
		} while ($env{'loop'});

	} elsif ($env{'action'} eq "pending_merges_family_group") {
		traverseJSONPages($range_begin, $range_end, "PENDING_CONFLICTS", $left_id);

	} elsif ($env{'action'} eq "pending_merge") {
		if (!$left_id || !$right_id) {
			print STDERR "\nERROR: You must specify two profile IDs, you only specified one\n";
			exit();
		}
		validateProfileID($left_id);
		validateProfileID($right_id);
		analyzePendingMerge($left_id, $right_id);

	} elsif ($env{'action'} eq "tree_conflicts") {
		do {
			traverseJSONPages($range_begin, $range_end, "TREE_CONFLICTS", 0);
			system "rm -rf $env{'datadir'}/*" if ($env{'loop'});
		} while ($env{'loop'});

	} elsif ($env{'action'} eq "tree_conflicts_family_group") {
		validateProfileID($left_id);
		analyzeTreeConflict($left_id, "parent");
		analyzeTreeConflict($left_id, "siblings");
		analyzeTreeConflict($left_id, "partner");
		analyzeTreeConflict($left_id, "children");
		do {
			$env{'matches'} = 0;
			traverseJSONPages($range_begin, $range_end, "TREE_CONFLICTS", $left_id);
		} while ($env{'matches'} > 0);

	} elsif ($env{'action'} eq "tree_conflict") {
		validateProfileID($left_id);
		analyzeTreeConflict($left_id, "parent");
		analyzeTreeConflict($left_id, "siblings");
		analyzeTreeConflict($left_id, "partner");
		analyzeTreeConflict($left_id, "children");

	} elsif ($env{'action'} eq "tree_matches") {
		printDebug($DBG_PROGRESS, "NOTE: The -all option is not supported for Tree Matches\n") if $env{'all_of_geni'};
		$env{'all_of_geni'} = 0;

		do {
			traverseJSONPages($range_begin, $range_end, "TREE_MATCHES", 0);
			system "rm -rf $env{'datadir'}/*" if ($env{'loop'});
		} while ($env{'loop'});

	} elsif ($env{'action'} eq "tree_match") {
		validateProfileID($left_id);
		analyzeTreeMatch($left_id);

	} elsif ($env{'action'} eq "stack") {
		validateProfileID($left_id);
		stackProfiles($left_id, $right_id);

	} elsif ($env{'action'} eq "data_conflicts") {
		do {
			traverseJSONPages($range_begin, $range_end, "DATA_CONFLICTS", 0);
			system "rm -rf $env{'datadir'}/*" if ($env{'loop'});
		} while ($env{'loop'});

	} elsif ($env{'action'} eq "data_conflict") {
		validateProfileID($left_id);
		analyzeDataConflict($left_id);

	} elsif ($env{'action'} eq "check_public") {
		validateProfileID($left_id);
		checkPublic($left_id);

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

}

__END__
46,805,758 big tree profiles on 10/29/2010

TODO
- test the new check_public API
	- if we check_public and it fails store that in a file somewhere so we don't do it over and over
- test half-siblings once they fix this in the API
- 6000000007224268070 vs 6000000003243493709 has a profile with the birthdate as part of the name
  We could fix this.
	-cleanupName  pre-clean: Samuel Seabury b. 10 Dec 1640
	-cleanupName post-clean: samuel seabury b dec 1640
