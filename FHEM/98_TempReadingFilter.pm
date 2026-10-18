# 98_TempReadingFilter.pm
# Version 1.0.0.7 (2026-10-16)
#
# Independent FHEM community module initiated by Frank Parussel.
# Contributions and possible future adoption by the FHEM community are welcome.
# This is currently not an official FHEM module.
#
# Copyright (C) 2026 Frank Parussel.
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Project information: https://153er-netz.de/seiten/entwicklung.html

=for comment
####################################################################################################
#
#       98_TempReadingFilter.pm
#       The TempReadingFilter device is used to delay and control the forwarding
#       of temperature readings depending on actuator states.
#
#       Typical use cases:
#       - Floor heating systems
#       - Valve controlled room temperature stabilization
#       - Plot continuity for long inactive heating periods
#       - Timeout prevention for monitoring devices
#
#       The module delays sensor forwarding after actuator activation
#       and forwards values 1:1 while the actuator is active.
#
#       Additionally a configurable keepAlive mechanism can cyclically
#       refresh the last valid reading while the actuator is inactive.
#
#       This file is part of fhem.
#
#       Fhem is free software: you can redistribute it and/or modify
#       it under the terms of the GNU General Public License as published by
#       the Free Software Foundation, either version 2 of the License, or
#       (at your option) any later version.
#
#       Fhem is distributed in the hope that it will be useful,
#       but WITHOUT ANY WARRANTY; without even the implied warranty of
#       MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
#       GNU General Public License for more details.
#
#       You should have received a copy of the GNU General Public License
#       along with fhem. If not, see <http://www.gnu.org/licenses/>.
#
####################################################################################################
#
# V 1.0.0.1
#  15.05.2026 - Initial version:
#               delayed forwarding of temperature readings based on actuator state.
#
# V 1.0.0.2
#  15.05.2026 - Feature:
#               added processing reading for internal state handling.
#
# V 1.0.0.3
#  15.05.2026 - Feature:
#               added automatic initialization using current sensor value.
#
# V 1.0.0.4
#  15.05.2026 - Feature:
#               added direct 1:1 pass-through while actuator is active.
#
# V 1.0.0.5
#  15.05.2026 - Feature:
#               added keepAliveInterval attribute to cyclically refresh
#               the last valid reading during inactive actuator states.
#
# V 1.0.0.6
#  15.05.2026 - Feature:
#               automatic initialization of default attributes.
#
# V 1.0.0.7
#  16.10.2026 - Fix:
#               cancel a pending delay when the actuator becomes inactive;
#               prevent a stale callback from bypassing a new delay.
#               Release attribution, version internal and project link added.
#
####################################################################################################
=cut

package main;

use strict;
use warnings;
use Time::HiRes qw(gettimeofday);

my $TempReadingFilter_Version = "1.0.0.7";

#####################################

sub TempReadingFilter_Initialize($);
sub TempReadingFilter_Define($$);
sub TempReadingFilter_Undef($$);
sub TempReadingFilter_Notify($$);
sub TempReadingFilter_StartProcessing($);
sub TempReadingFilter_KeepAlive($);

#####################################
# Initialize
#####################################

sub TempReadingFilter_Initialize($) {
    my ($hash) = @_;

    $hash->{DefFn}    = "TempReadingFilter_Define";
    $hash->{UndefFn}  = "TempReadingFilter_Undef";
    $hash->{NotifyFn} = "TempReadingFilter_Notify";

    $hash->{AttrList} =
          "delay "
        . "keepAliveInterval "
        . $readingFnAttributes;
}

#####################################
# Define
#####################################

sub TempReadingFilter_Define($$) {
    my ($hash, $def) = @_;

    my @a = split("[ \t]+", $def);

    return "wrong syntax: define <name> TempReadingFilter <sensorDevice> <sensorReading> <actorDevice> <actorState>"
      if (int(@a) != 6);

    my $name           = $a[0];
    my $sensorDevice   = $a[2];
    my $sensorReading  = $a[3];
    my $actorDevice    = $a[4];
    my $actorStateOn   = $a[5];

    $hash->{NAME}            = $name;
    $hash->{VERSION}         = $TempReadingFilter_Version;
    $hash->{SENSOR_DEVICE}   = $sensorDevice;
    $hash->{SENSOR_READING}  = $sensorReading;
    $hash->{ACTOR_DEVICE}    = $actorDevice;
    $hash->{ACTOR_STATE_ON}  = $actorStateOn;

    #################################
    # Default attributes
    #################################

    CommandAttr(undef, "$name delay 300")
      if (!defined(AttrVal($name, "delay", undef)));

    CommandAttr(undef, "$name keepAliveInterval 300")
      if (!defined(AttrVal($name, "keepAliveInterval", undef)));

    #################################
    # Initial Sensor Value
    #################################

    my $initial = ReadingsVal(
        $sensorDevice,
        $sensorReading,
        undef
    );

    readingsBeginUpdate($hash);

    if (defined($initial)) {

        readingsBulkUpdate(
            $hash,
            $sensorReading,
            $initial
        );

        readingsBulkUpdate(
            $hash,
            "state",
            $initial
        );

        readingsBulkUpdate(
            $hash,
            "processing",
            "initialized"
        );
    }
    else {

        readingsBulkUpdate(
            $hash,
            "processing",
            "noInitialValue"
        );
    }

    readingsEndUpdate($hash, 1);

    #################################
    # Register Notify
    #################################

    $hash->{NOTIFYDEV} =
        "$sensorDevice,$actorDevice";

    #################################
    # Start KeepAlive
    #################################

    TempReadingFilter_KeepAlive($hash);

    return undef;
}

#####################################
# Undef
#####################################

sub TempReadingFilter_Undef($$) {
    my ($hash, $arg) = @_;

    RemoveInternalTimer($hash);

    return undef;
}

#####################################
# Notify
#####################################

sub TempReadingFilter_Notify($$) {
    my ($hash, $dev) = @_;

    my $name           = $hash->{NAME};
    my $sensorDevice   = $hash->{SENSOR_DEVICE};
    my $sensorReading  = $hash->{SENSOR_READING};
    my $actorDevice    = $hash->{ACTOR_DEVICE};
    my $actorStateOn   = $hash->{ACTOR_STATE_ON};

    my $devName = $dev->{NAME};

    my $delay = AttrVal($name, "delay", 300);

    #################################
    # Current actor state
    #################################

    my $actorState = ReadingsVal(
        $actorDevice,
        "state",
        "off"
    );

    #################################
    # Actor OFF
    #################################

    if ($actorState ne $actorStateOn) {

        RemoveInternalTimer(
            $hash,
            "TempReadingFilter_StartProcessing"
        );

        delete $hash->{ACTIVE};
        delete $hash->{WAITING};
        delete $hash->{START_PROCESSING_AT};

        readingsSingleUpdate(
            $hash,
            "processing",
            "idle",
            1
        );

        return undef;
    }

    #################################
    # Actor ON -> Start delay
    #################################

    if ($actorState eq $actorStateOn
        && !$hash->{WAITING}
        && !$hash->{ACTIVE}) {

        $hash->{WAITING} = 1;
        $hash->{START_PROCESSING_AT} = gettimeofday() + $delay;

        readingsSingleUpdate(
            $hash,
            "processing",
            "waiting",
            1
        );

        InternalTimer(
            $hash->{START_PROCESSING_AT},
            "TempReadingFilter_StartProcessing",
            $hash,
            0
        );

        Log3(
            $name,
            3,
            "$name: waiting for delay ($delay sec)"
        );

        return undef;
    }

    #################################
    # Only sensor updates
    #################################

    return undef
        if ($devName ne $sensorDevice);

    #################################
    # ACTIVE -> Direct pass-through
    #################################

    if ($hash->{ACTIVE}) {

        my $value = ReadingsVal(
            $sensorDevice,
            $sensorReading,
            undef
        );

        return undef
            if (!defined($value));

        readingsBeginUpdate($hash);

        readingsBulkUpdate(
            $hash,
            $sensorReading,
            $value
        );

        readingsBulkUpdate(
            $hash,
            "state",
            $value
        );

        readingsBulkUpdate(
            $hash,
            "processing",
            "active"
        );

        readingsEndUpdate($hash, 1);

        Log3(
            $name,
            3,
            "$name: new value -> $value"
        );

        return undef;
    }

    return undef;
}

#####################################
# Start Processing
#####################################

sub TempReadingFilter_StartProcessing($) {
    my ($hash) = @_;

    my $name = $hash->{NAME};
    my $actorState = ReadingsVal(
        $hash->{ACTOR_DEVICE},
        "state",
        "off"
    );

    return
        if (!$hash->{WAITING}
            || $actorState ne $hash->{ACTOR_STATE_ON}
            || !defined($hash->{START_PROCESSING_AT})
            || gettimeofday() < $hash->{START_PROCESSING_AT});

    delete $hash->{WAITING};
    delete $hash->{START_PROCESSING_AT};

    $hash->{ACTIVE} = 1;

    readingsSingleUpdate(
        $hash,
        "processing",
        "active",
        1
    );

    Log3(
        $name,
        3,
        "$name: processing activated"
    );
}

#####################################
# KeepAlive
#####################################

sub TempReadingFilter_KeepAlive($) {
    my ($hash) = @_;

    my $name            = $hash->{NAME};
    my $sensorReading   = $hash->{SENSOR_READING};

    my $interval = AttrVal(
        $name,
        "keepAliveInterval",
        300
    );

    #################################
    # Disabled
    #################################

    return
        if ($interval <= 0);

    #################################
    # Only when NOT active
    #################################

    if (!$hash->{ACTIVE}) {

        my $lastValue = ReadingsVal(
            $name,
            $sensorReading,
            undef
        );

        if (defined($lastValue)) {

            readingsBeginUpdate($hash);

            readingsBulkUpdate(
                $hash,
                $sensorReading,
                $lastValue
            );

            readingsBulkUpdate(
                $hash,
                "state",
                $lastValue
            );

            readingsEndUpdate($hash, 1);

            Log3(
                $name,
                4,
                "$name: keepAlive -> $lastValue"
            );
        }
    }

    #################################
    # Restart timer
    #################################

    InternalTimer(
        gettimeofday() + $interval,
        "TempReadingFilter_KeepAlive",
        $hash,
        0
    );
}

1;

=pod
=item helper
=item summary    delays and controls forwarding of temperature readings depending on actuator states
=item summary_DE verzögert und steuert die Weitergabe von Temperaturwerten abhängig von Aktorzuständen

=begin html

<a id="TempReadingFilter"></a>
<h3>TempReadingFilter</h3>
<ul>

    <a id="TempReadingFilter-define"></a>
    <b>Define</b>
    <ul>
        <code>
        define &lt;name&gt; TempReadingFilter &lt;sensorDevice&gt; &lt;reading&gt; &lt;actorDevice&gt; &lt;actorOnState&gt;
        </code>
        <br><br>

        Example:<br>
        <code>
        define OG_Windfang_RL_TF TempReadingFilter OG_Windfang_RL realtemperature OG_Windfang_Ventil_PortB0 on
        </code>
    </ul>

    <br>

    <a id="TempReadingFilter-description"></a>
    <b>Description</b>
    <ul>
        The module delays forwarding of temperature readings after an actuator
        switches to its active state.<br><br>

        After the configured delay time has elapsed,
        all incoming readings are forwarded 1:1 while the actuator remains active.<br><br>

        When the actuator switches off,
        forwarding stops and the last valid value remains stored.<br><br>

        Optionally the module can cyclically refresh the last value
        while inactive to avoid plot interruptions and timeout alarms.
    </ul>

    <br>

    <b>Project information</b>
    <ul>
        <a href="https://153er-netz.de/seiten/entwicklung.html">153er-netz.de / Development</a><br>
        Independent community module; currently not an official FHEM module.
    </ul>

    <br>

    <a id="TempReadingFilter-readings"></a>
    <b>Readings</b>
    <ul>

        <li>
            <b>state</b><br>
            Contains the last forwarded temperature value.
        </li>

        <br>

        <li>
            <b>&lt;reading&gt;</b><br>
            Contains the processed sensor reading
            using the original reading name from define.
        </li>

        <br>

        <li>
            <b>processing</b><br>
            Internal processing state.<br><br>

            Possible values:
            <ul>
                <li>initialized</li>
                <li>waiting</li>
                <li>active</li>
                <li>idle</li>
                <li>noInitialValue</li>
            </ul>
        </li>

    </ul>

    <br>

    <a id="TempReadingFilter-attr"></a>
    <b>Attributes</b>
    <ul>

        <li>
            <b>delay</b><br>
            Delay time in seconds after actuator activation
            before values are forwarded.<br><br>

            Default: 300
        </li>

        <br>

        <li>
            <b>keepAliveInterval</b><br>
            Interval in seconds for cyclic refresh
            of the last valid value while actuator is inactive.<br><br>

            Prevents:
            <ul>
                <li>plot interruptions</li>
                <li>timeout alarms</li>
                <li>missing periodic updates</li>
            </ul>

            0 = disabled<br><br>

            Default: 300
        </li>

    </ul>

</ul>

=end html


=begin html_DE

<a id="TempReadingFilter"></a>
<h3>TempReadingFilter</h3>
<ul>

    <a id="TempReadingFilter-define-de"></a>
    <b>Define</b>
    <ul>
        <code>
        define &lt;name&gt; TempReadingFilter &lt;sensorDevice&gt; &lt;reading&gt; &lt;actorDevice&gt; &lt;actorOnState&gt;
        </code>
        <br><br>

        Beispiel:<br>
        <code>
        define OG_Windfang_RL_TF TempReadingFilter OG_Windfang_RL realtemperature OG_Windfang_Ventil_PortB0 on
        </code>
    </ul>

    <br>

    <a id="TempReadingFilter-description-de"></a>
    <b>Beschreibung</b>
    <ul>
        Das Modul verzögert die Weitergabe von Temperaturwerten,
        nachdem ein Aktor seinen aktiven Zustand erreicht hat.<br><br>

        Nach Ablauf der konfigurierten Verzögerungszeit
        werden alle eingehenden Werte 1:1 übernommen,
        solange der Aktor aktiv bleibt.<br><br>

        Wird der Aktor ausgeschaltet,
        stoppt die Weitergabe und der letzte gültige Wert bleibt erhalten.<br><br>

        Optional kann der letzte Wert zyklisch erneut geschrieben werden,
        um Plot-Unterbrechungen und Timeout-Meldungen zu vermeiden.
    </ul>

    <br>

    <b>Projektinformationen</b>
    <ul>
        <a href="https://153er-netz.de/seiten/entwicklung.html">153er-netz.de / Entwicklung</a><br>
        Unabhängiges Community-Modul; derzeit kein offizielles FHEM-Modul.
    </ul>

    <br>

    <a id="TempReadingFilter-readings-de"></a>
    <b>Readings</b>
    <ul>

        <li>
            <b>state</b><br>
            Enthält den letzten weitergegebenen Temperaturwert.
        </li>

        <br>

        <li>
            <b>&lt;reading&gt;</b><br>
            Enthält den bearbeiteten Sensorwert
            unter dem originalen Readingnamen aus dem Define.
        </li>

        <br>

        <li>
            <b>processing</b><br>
            Interner Verarbeitungsstatus.<br><br>

            Mögliche Werte:
            <ul>
                <li>initialized</li>
                <li>waiting</li>
                <li>active</li>
                <li>idle</li>
                <li>noInitialValue</li>
            </ul>
        </li>

    </ul>

    <br>

    <a id="TempReadingFilter-attr-de"></a>
    <b>Attribute</b>
    <ul>

        <li>
            <b>delay</b><br>
            Verzögerungszeit in Sekunden nach Aktoraktivierung,
            bevor Werte übernommen werden.<br><br>

            Default: 300
        </li>

        <br>

        <li>
            <b>keepAliveInterval</b><br>
            Intervall in Sekunden,
            in dem der letzte gültige Wert zyklisch erneut geschrieben wird,
            solange der Aktor inaktiv ist.<br><br>

            Verhindert:
            <ul>
                <li>Unterbrechungen in SVG-Plots</li>
                <li>Timeout-Meldungen</li>
                <li>fehlende zyklische Aktualisierungen</li>
            </ul>

            0 = deaktiviert<br><br>

            Default: 300
        </li>

    </ul>

</ul>

=end html_DE
=cut
