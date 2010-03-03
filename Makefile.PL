use 5.010000;
use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    NAME              => 'IRC::RemoteControl',
    VERSION_FROM      => 'lib/IRC/RemoteControl.pm', # finds $VERSION
    PREREQ_PM         => {
        'AnyEvent' => 0,
        'Moose' => 0,
        'AnyEvent::IRC::Client' => 0,  
    },
    ($] >= 5.005 ?     ## Add these new keywords supported since 5.005
      (ABSTRACT_FROM  => 'lib/IRC/RemoteControl.pm', # retrieve abstract from module
       AUTHOR         => 'Thaddeus Wooster <wooster@cpan.org>') : ()),
);
