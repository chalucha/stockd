module stockd.conv.tfconv;

import std.range;
import stockd.defs;

/**
 * Converts input Bar range to higher time frame range
 * 
 * For example can make h1 bars from m1 (hour TF from minute TF)
 */
template tfConv(uint factor)
{
    auto tfConv(Range)(Range r) if (isInputRange!Range && is(ElementType!Range : Bar))
    {
        return TimeFrameConv!(Range)(r, factor);
    }
}

private struct TimeFrameConv(T) if (isInputRange!T && is(ElementType!T : Bar))
{
    import std.datetime;

    enum guessNumBar = 10;

    private InputRange!(ElementType!T) _input;
    private uint _factor;
    private Bar currentBar;
    private TimeFrame _targetTF;
    private DateTime _lastWaitTime;
    private ubyte _eodHour;

    /**
     * Params:
     *  input - input bar range
     *  factor - time frame multiplyer
     *  eodHour - hour at which trading session ends in UTC time
     */
    this(T input, uint factor, ubyte eodHour = 22)  //TODO: check if differ in summer and winter times - than session object should be passed (it would be more generic)
    {
        import std.array;
        import std.range;
        import std.exception : enforce;

        enforce(!input.empty);
        enforce(factor > 0);

        this._factor = factor;

        auto tfGuessArray = take(&input, guessNumBar).array();
        if(tfGuessArray.length<2) assert(0, "Not enough input bars");

        _targetTF = guessTimeFrame(tfGuessArray) * factor;

        //as part of input range was consumed for TF guessing, chain guess buffer with the input range
        _input = inputRangeObject(chain(tfGuessArray, input));

        //prepare first Bar
        this.popFront();
    }

    @property @safe @nogc nothrow bool empty() const
    {
        return currentBar == Bar.init;
    }

    @property auto ref front()
    {
        assert(currentBar != Bar.init);

        return currentBar;
    }

    void popFront()
    {
        assert(!empty || !_input.empty);

        currentBar = Bar.init;

        while(!_input.empty)
        {
            if(_input.front.time <= _lastWaitTime) //reading through to valid time
            {
                //just add to current
                currentBar ~= _input.front;
                _input.popFront();

                if(currentBar.time == _lastWaitTime) break; //we've got one
            }
            else if(_input.front.time > _lastWaitTime) //new bar started
            {
                auto waitTime = nextValidTime(_input.front);

                assert(_lastWaitTime < waitTime);

                if(currentBar == Bar.init) //this means that we just got the first Bar from the input
                {
                    _lastWaitTime = waitTime; //just set the new time and go on
                }
                else
                {
                    //return current one even if it's not complete
                    currentBar.time = _lastWaitTime; //at least set the correct time
                    _lastWaitTime = waitTime;
                    break;
                }
            }
        }

        //filter out weekend bars from input
        //TODO: not sure if this should be here at all -> input validation in marketData range?
        if(_targetTF.origin == Origin.day && _factor == 1 && (currentBar.time.dayOfWeek == DayOfWeek.sun || currentBar.time.dayOfWeek == DayOfWeek.sat))
        {
            //ignore this one and get next
            popFront();
        }
    }

    /// gets next time we wait for from the current bar
    private DateTime nextValidTime(Bar bar)
    {
        final switch(_targetTF.origin)
        {
            case Origin.minute:
                uint rest = bar.time.minute % _factor;
                if(rest == 0) return bar.time;// + dur!"minutes"(_factor);
                else return bar.time + dur!"minutes"(_factor - rest);
            case Origin.hour:
                auto next = bar.time;
                if (next.minute != 0) next += dur!"minutes"(60 - next.minute);
                uint rest = next.hour % _factor;
                if (rest == 0) return next;
                else return next + dur!"hours"(_factor - rest);
            case Origin.day:
                auto next = bar.time;
                if (next.minute != 0) next += dur!"minutes"(60 - next.minute);
                if (next.hour < _eodHour) next += dur!"hours"(_eodHour - next.hour);
                if (next.hour > _eodHour) next += dur!"hours"(24 - next.hour + _eodHour);
                if (_factor == 1 || next.dayOfWeek == DayOfWeek.fri)
                {
                    if (bar.time == next && bar.time.dayOfWeek == DayOfWeek.sun)
                    {
                        //ensure usage of first week session bar
                        bar.time += dur!"minutes"(1);
                        return nextValidTime(bar);
                    }
                    return next;
                }
                //set to friday
                if (next.dayOfWeek == DayOfWeek.sat) return next + dur!"days"(6);
                return next + dur!"days"(DayOfWeek.fri - next.dayOfWeek);
            case Origin.week:
                return bar.time;
        }
    }
}

unittest
{
    import std.algorithm;
    import std.conv;
    import std.stdio;
    import std.range;

    import stockd.data;

    // Test M1 to M5
    string barsText = r"20110715 205500;1.4154;1.41545;1.41491;1.41498;33450
        20110715 205600;1.415;1.4152;1.41481;1.41481;11360
        20110715 205700;1.41486;1.41522;1.41477;1.41486;31010
        20110715 205800;1.41488;1.41506;1.41473;1.41502;15170
        20110715 205900;1.41489;1.41561;1.41486;1.41561;15280
        20110715 210000;1.41549;1.41549;1.41532;1.41532;540";

    auto expected = marketData("20110715 205500;1.41540;1.41545;1.41491;1.41498;33450\n"
        ~"20110715 210000;1.41500;1.41561;1.41473;1.41532;73360").array;
                               
    auto bars = marketData(barsText).tfConv!(5);

    writeln("Test M1 -> M5");
    int i;
    foreach(b; bars)
    {
//        writeln(b);
//        writeln(expected[i], " - expected");
        assert(expected[i++] == b);
    }
    assert(i == 2);

    // Test M5 to M5 - should return the same data as input
    barsText = "20110715 205500;1.4154;1.41545;1.41491;1.41498;33450\n"
        ~ "20110715 210000;1.415;1.41561;1.41473;1.41532;73360";
    
    bars = marketData(barsText).tfConv!(1);

    writeln("Test M5 -> M5");
    i = 0;
    foreach(b; bars)
    {
        assert(expected[i++] == b);
    }
    assert(i == 2);

    //TODO: Add more tests - more time frames, tests with invalid input, etc
}