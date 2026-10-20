#
# berry script for a heating controller
#

import json
import string
import mqtt
import math
import persist

var loopTime=10000
var maxStep=loopTime

var minValveTime=600

var targetTemp
var targetTempDiff
var nightShift
var nightMode
var maxTempForward

var schedule = {
    0: {"dayStart": {"hour": 6, "minute": 0}, "dayDuration": 1020},  # Sunday (6am to 11pm)
    1: {"dayStart": {"hour": 6, "minute": 0}, "dayDuration": 1020},  # Monday (6am to 11pm)
    2: {"dayStart": {"hour": 6, "minute": 0}, "dayDuration": 1020},  # Tuesday (6am to 11pm)
    3: {"dayStart": {"hour": 6, "minute": 0}, "dayDuration": 1020},  # Wednesday (6am to 11pm)
    4: {"dayStart": {"hour": 6, "minute": 0}, "dayDuration": 1020},  # Thursday (6am to 11pm)
    5: {"dayStart": {"hour": 6, "minute": 0}, "dayDuration": 1020},  # Friday (6am to 11pm)
    6: {"dayStart": {"hour": 6, "minute": 0}, "dayDuration": 1020}   # Saturday (6am to 11pm)
}

if persist.has("maxTempForward")
    maxTempForward=persist.maxTempForward
else
    maxTempForward=40    
end

if persist.has("targetTempDiff")
    targetTempDiff=persist.targetTempDiff
else
    targetTempDiff=10
end

if persist.has("nightShift")
    nightShift=persist.nightShift
else
    nightShift=-5
end

if persist.has("nightMode")
    nightMode=persist.nightMode
else
    nightMode=false
end

if persist.has("targetTemp") 
    targetTemp=persist.targetTemp
else
    targetTemp=30
end

var minStep
if persist.has("minStep")
    minStep=persist.minStep
else
    minStep=500
end

var setTemp=targetTemp

var Kp=500
var Ki=2
var Kd=1200

if persist.has("Kp")
    Kp=persist.Kp
end
if persist.has("Ki")
    Ki=persist.Ki
end
if persist.has("Kd")
    Kd=persist.Kd
end

var valveOpenPin=1
var valveClosePin=0
var pumpPin=2

# Set custom button names
tasmota.cmd("WebButton1 Valve Close")
tasmota.cmd("WebButton2 Valve Open")
tasmota.cmd("WebButton3 Pump")

var extTempForward
var extTempReturn
var intTempForward
var intTempReturn

# Temperature history for derivative calculation
var tempHistory = []
var maxTempHistory = 15  # Keep last 15 readings (150 seconds at 10s loop)

var aussentemperatur=20
var temperaturFaktor=1
var temperaturKorrektur=13
var nachtAbsenkung=5

if persist.has("aussentemperatur")
    aussentemperatur=persist.aussentemperatur
end
if persist.has("temperaturKorrektur")
    temperaturKorrektur=persist.temperaturKorrektur
end
if persist.has("temperaturFaktor")
    temperaturFaktor=persist.temperaturFaktor
end
if persist.has("nachtAbsenkung")
    nachtAbsenkung=persist.nachtAbsenkung
end

var nachtMode=0

class pump
    var status
    var output
    var verbose
    var name

    def init(name,pin)
        self.name=name
        self.output=pin
        self.status=false
        self.verbose=false
    end

    def setVerbose(v)
        self.setVerbose=bool(v)
    end

    def start()
        if self.verbose==true
            print("starting Pump ", self.name)
        end
        tasmota.set_power(self.output,true)
        self.status=true
    end

    def stop()
        if self.verbose==true
            print("stopping Pump ", self.name)
        end
        tasmota.set_power(self.output,false)
        self.status=false
    end  

    def getStatus()
        return self.status
    end
end

umwaelzpumpe=pump("Umwälzpumpe",pumpPin)

class valve
    var name
    var minStep
    var sumup 
    var sumupVal 
    var sumupFactor 

    var valveTotalTime
    
    var pinOpen
    var pinClose
    var valveLockout
    var verbose

    var msPerPercent
    var currentPos
    
    var stopCloseCB
    var stopOpenCB
    
    var valvePrime
    var valveReset

    var isResetting

    def init(name, pinOpen, pinClose)
        self.pinOpen=pinOpen
        self.pinClose=pinClose
        self.name=name
        self.sumup=false
        self.sumupVal=0
        self.sumupFactor=0.5
        self.minStep=500
        self.isResetting=false
        self.valveLockout=false

        self.msPerPercent=360
        if persist.has("valvePos")
             self.currentPos=persist.valvePos
        else
            self.reset()
        end

        if persist.has("valvePrime")
            self.valvePrime=persist.valvePrime
        else
            self.valvePrime=250
        end

        if persist.has("valveReset")
            self.valveReset=persist.valveReset
        else
            self.valveReset=250
        end

        #closures for callbacks
        self.stopCloseCB = def () self.stopClose() end
        self.stopOpenCB = def () self.stopOpen() end
    end

    def reset()
        self.isResetting=true
        self.close(self.valveReset*self.msPerPercent)
    end

    def setPosition(p)
        if p<0
            p=0
        end
        if p>100
            p=100
        end
        self.move((p-self.currentPos)*self.msPerPercent)
        self.currentPos=p
        persist.valvePos=self.currentPos
    end

    def getPosition()
        return self.currentPos
    end

    def setMsPerPercent(ms)
        self.msPerPercent=ms
    end

    def setVerbose(v)
        self.verbose=bool(v)
    end

    def setMinStep(ms)
        self.minStep=ms
    end

    def setSumup(s)
        self.sumup=bool(s)
    end

    def setSumupFactor(f)
        self.sumupFactor=f
    end

    def setValvePrime(v)
        self.valvePrime=v
        persist.valvePrime=v
    end

    def setValveReset(v)
        self.valveReset=v
        persist.valveReset=v
    end

    def stopOpen()
        tasmota.set_power(self.pinOpen,false)
        self.valveLockout=false

        if self.isResetting
            self.isResetting=false
            self.currentPos=0
            persist.valvePos=self.currentPos
        end
        persist.valvePos=self.currentPos
        mqtt.publish("Heizung/valveposition",string.format("%f", (self.currentPos)))
    end 

    def stopClose()
        tasmota.set_power(self.pinClose,false)
        self.valveLockout=false
        if self.isResetting
            print("priming valve")
            self.open(self.valvePrime*self.msPerPercent)
        end
        persist.valvePos=self.currentPos
        mqtt.publish("Heizung/valveposition",string.format("%f", (self.currentPos)))
    end

    def open(t)
        if self.valveLockout != true
            if self.verbose
                print("opening valve ", self.name)
            end
            self.valveLockout=true
            tasmota.set_power(self.pinClose,false)
            tasmota.set_power(self.pinOpen,true)
            tasmota.set_timer(t,self.stopOpenCB)
            if !self.isResetting
                self.currentPos=self.currentPos+t/self.msPerPercent
            end
        end 
    end

    def close(t)
        if self.valveLockout !=true 
            if self.verbose==true
                print("closing valve ", self.name)
            end
            self.valveLockout=true  
            tasmota.set_power(self.pinOpen,false)
            tasmota.set_power(self.pinClose,true)
            tasmota.set_timer(t,self.stopCloseCB)
            if !self.isResetting
                self.currentPos=self.currentPos-t/self.msPerPercent
            end
        end 
    end

    def move(t)
        if self.verbose
            print("moving valve for",t)
        end
        t=int(t)
        if math.abs(t)<self.minStep
            if self.sumup
                self.sumupVal=t+self.sumupVal*self.sumupFactor
                if math.abs(self.sumupVal)>=self.minStep
                    self.move(self.sumupVal)
                end
            end
        else
            t=t+self.sumupVal
            if t<0
                if self.verbose
                    print("open valve for", -t)
                end
                self.open(-t)
            else
                if self.currentPos>0
                    if self.verbose
                        print("close valve for", t)
                    end
                    self.close(t)
                end
            end
            self.sumupVal=0
        end
        if self.verbose
            print("current position:",self.currentPos)
        end
    end
end

mischventil=valve("Mischventil",valveOpenPin, valveClosePin)

class PID
    var name
    var Ki,Kd,Kp
    var setPoint
    var sensorValue
    var previousError
    var verbose
    var PID_p,PID_i,PID_d

    var deadband

    def setVerbose(v)
        self.verbose=bool(v)
    end

    def init(Name,Kp,Ki,Kd,Sp)
        self.name=Name
        self.Ki=Ki
        self.Kd=Kd
        self.Kp=Kp
        self.setPoint=Sp
        self.previousError=0

        self.deadband=0
        if persist.has("deadband")
            self.deadband=persist.deadband
        else
            self.deadband=0
        end
    end

    def setKi(i)
        if self.verbose
            print("setting Ki to",i)
        end
        self.Ki=i
        persist.Ki=i  
    end

    def setKd(d)
        if self.verbose
            print("setting Kd to",d)
        end
        self.Kd=d
        persist.Kd=d
    end

    def setKp(p)
        if self.verbose
            print("setting Kp to",p)
        end
        self.Kp=p
        persist.Kp=p
    end 

    def setSetPoint(sp)
        if self.verbose
            print("setting Setpoint to",sp)
        end
        self.setPoint=sp
        # clear integrative error accumulated with the old setpoint
        self.PID_i=0
    end

    def setDeadband(db)
        if self.verbose
            print("setting Deadband to",db)
        end
        self.deadband=db
        persist.deadband=db
    end

    def doPID(v)
        var Error
        if self.verbose
            print("starting PID loop for value:",v)
        end
        self.sensorValue=v
        Error=self.sensorValue-self.setPoint
        if math.abs(Error)<self.deadband
            if self.verbose
                print("   Error within deadband")
            end
            return 0
        end
        if self.verbose
            print("   Kp:",self.Kp)
            print("   Ki:",self.Ki)
            print("   Kd:",self.Kd)

            print("   Error:",Error)
            print("   previousError:",self.previousError)
        end
        self.PID_p=self.Kp*Error
        self.PID_d=self.Kd*(Error-self.previousError)
        self.PID_i=self.PID_i+(self.Ki*Error)
        if self.PID_i>100 self.PID_i=100 end
        if self.PID_i<-100 self.PID_i=-100 end
        if self.verbose
            print("   PID_p:",self.PID_p)
            print("   PID_i:",self.PID_i)
            print("   PID_d:",self.PID_d)
        end
        self.previousError=Error
        return self.PID_p+self.PID_d+self.PID_i
    end
end

regler=PID("Heizregler",Kp,Ki,Kd,setTemp)

def min(a,b)
    if a<b
        return a
    else
        return b
    end
end

def max(a,b)
    if a>b
        return a
    else
        return b
    end
end

def getTemperatures()
  var sensorValues=json.load(tasmota.read_sensors())
  extTempForward=sensorValues['DS18B20-3']['Temperature']+6.5
  extTempReturn=sensorValues['DS18B20-1']['Temperature']+5.7
  intTempForward=sensorValues['DS18B20-4']['Temperature']
  intTempReturn=sensorValues['DS18B20-2']['Temperature']-4.5
end

# Calculate 1st derivative (temperature slope) using linear regression
def calculateTempSlope()
    var n = size(tempHistory)
    if n < 2 return 0.0 end
    
    # Use last 6 points (60 seconds) for slope calculation
    var startIdx = n - 6
    if startIdx < 0 startIdx = 0 end
    
    var sumTime = 0.0
    var sumTemp = 0.0
    var sumTimeTemp = 0.0
    var sumTimeSq = 0.0
    var count = 0
    
    var firstTime = tempHistory[startIdx]["time"]
    
    for i: startIdx..(n-1)
        var reading = tempHistory[i]
        var t = (reading["time"] - firstTime) / 1000.0  # Seconds from start
        var temp = reading["temp"]
        
        sumTime += t
        sumTemp += temp
        sumTimeTemp += t * temp
        sumTimeSq += t * t
        count += 1
    end
    
    if count < 2 return 0.0 end
    
    # Linear regression: slope = (n*Σ(xy) - Σx*Σy) / (n*Σ(x²) - (Σx)²)
    var denominator = count * sumTimeSq - sumTime * sumTime
    if math.abs(denominator) < 0.001 return 0.0 end
    
    var slope = (count * sumTimeTemp - sumTime * sumTemp) / denominator
    
    return slope
end

# Calculate 2nd derivative (temperature acceleration) from slope changes
def calculateTempAcceleration()
    var n = size(tempHistory)
    if n < 8 return 0.0 end  # Need enough data for reliable 2nd derivative
    
    # Calculate slope for last 3 points and first 3 points of recent history
    var midPoint = n - 3
    
    # Recent slope (last 3 points)
    var recentSlope = 0.0
    if midPoint >= 3
        var t1 = tempHistory[midPoint]["time"]
        var temp1 = tempHistory[midPoint]["temp"]
        var t2 = tempHistory[n-1]["time"]
        var temp2 = tempHistory[n-1]["temp"]
        var deltaTime = (t2 - t1) / 1000.0
        if deltaTime > 0
            recentSlope = (temp2 - temp1) / deltaTime
        end
    end
    
    # Earlier slope (points 3-6 back)
    var earlierSlope = 0.0
    var earlierIdx = n - 6
    if earlierIdx >= 0 && midPoint < n
        var t1 = tempHistory[earlierIdx]["time"]
        var temp1 = tempHistory[earlierIdx]["temp"]
        var t2 = tempHistory[midPoint]["time"]
        var temp2 = tempHistory[midPoint]["temp"]
        var deltaTime = (t2 - t1) / 1000.0
        if deltaTime > 0
            earlierSlope = (temp2 - temp1) / deltaTime
        end
    end
    
    # Acceleration is change in slope over time
    var timeBetweenSlopes = (tempHistory[n-1]["time"] - tempHistory[earlierIdx]["time"]) / 1000.0
    if timeBetweenSlopes > 0
        return (recentSlope - earlierSlope) / timeBetweenSlopes
    end
    
    return 0.0
end



# Function to get the day of the week and local time
def getDayOfWeekAndLocalTime()
    # Get the full map containing the local time and other information
    var rtcInfo = tasmota.rtc()

    # Extract the local time in seconds since the epoch
    var localTime = rtcInfo["local"]

    # Convert the local time to a human-readable format
    var formattedTime = tasmota.strftime("%Y-%m-%d %H:%M:%S", localTime)

    # Parse the formatted time to get the components
    var date = tasmota.strptime(formattedTime, "%Y-%m-%d %H:%M:%S")

    # Extract the day of the week and local time
    var dayOfWeek = date["weekday"]  # 0 = Sunday, 1 = Monday, ..., 6 = Saturday
    var hour = date["hour"]
    var minute = date["min"]
    var second = date["sec"]

    # Create a map to return the results
    var result = {
        "dayOfWeek": dayOfWeek,
        "hour": hour,
        "minute": minute,
        "second": second
    }

    return result
end

def setHeatingDay()
    print("Setting heating to day mode")
    nightMode=false
    persist.nightMode=nightMode
end

def setHeatingNight()
    print("Setting heating to night mode")
    nightMode=true
    persist.nightMode=nightMode
end

def setupCronTimers()
    for day : schedule.keys()
        var times = schedule[day]
        var dayStart = times["dayStart"]
        var dayDuration = times["dayDuration"]

        var startHour = dayStart["hour"]
        var startMinute = dayStart["minute"]
        var endHour = ((startHour * 60 + startMinute + dayDuration) / 60) % 24
        var endMinute = (startHour * 60 + startMinute + dayDuration) % 60

        # Cron pattern for dayStart
        var startCronPattern = string.format("0 %d %d * * %d", startMinute, startHour, day)
        print ("adding timer for",startCronPattern)
        tasmota.add_cron(startCronPattern, setHeatingDay, string.format("heatingOn_%d", day))

        # Calculate the day of the week for dayEnd, adjusting for overflow
        var endDay = (day + (startHour * 60 + startMinute + dayDuration) / 1440) % 7

        # Cron pattern for dayEnd
        var endCronPattern = string.format("0 %d %d * * %d", endMinute, endHour, endDay)
        print ("adding timer for",endCronPattern)
        tasmota.add_cron(endCronPattern, setHeatingNight, string.format("heatingOff_%d", day))
    end
end

def controlLoop()
  getTemperatures()
  
  # Update temperature history
  tempHistory.push({
    "temp": intTempForward,
    "time": tasmota.millis()
  })
  
  # Keep only recent history
  if size(tempHistory) > maxTempHistory
    tempHistory.remove(0)
  end
  
  # Calculate derivatives
  var tempSlope = calculateTempSlope()
  var tempAcceleration = calculateTempAcceleration()
  
  print()  
  print("====Temperaturen====")  
  mqtt.publish("Heizung/vorlaufExtern",string.format("%f", extTempForward))
  mqtt.publish("Heizung/ruecklaufExtern",string.format("%f", extTempReturn))
  mqtt.publish("Heizung/vorlaufIntern",string.format("%f", intTempForward))
  mqtt.publish("Heizung/ruecklaufIntern",string.format("%f", intTempReturn))
  
  # Publish derivatives
  mqtt.publish("Heizung/tempSlope",string.format("%.3f", tempSlope*60))
  mqtt.publish("Heizung/tempAcceleration",string.format("%.4f", tempAcceleration*60))

  print("====Temperaturen====")
  print("Aussentemperatur:", aussentemperatur)
  print("Zieltemperatur:", regler.setPoint)
  print("Vorlauf Extern:", extTempForward)
  print("Rücklauf Extern:", extTempReturn)
  print("Vorlauf Intern:", intTempForward)
  print("Rücklauf Intern:", intTempReturn)
  print("Temp Slope:", string.format("%.6f", tempSlope), "°C/s")
  print("Temp Acceleration:", string.format("%.8f", tempAcceleration), "°C/s²")
  print("====================")
  #
  # core control 
  #
  mischventil.move(regler.doPID(intTempForward))
     
  tasmota.set_timer(loopTime,controlLoop)
end

def updateSetPoint()
    var setpoint=targetTemp-((aussentemperatur-temperaturKorrektur)*temperaturFaktor)
    if nightMode==true
        setpoint=setpoint+nightShift
    end
    regler.setSetPoint(setpoint)
    mqtt.publish("Heizung/setpoint",string.format("%f", setpoint))
end

def handle_topic_aussentemperatur(topic, idx, payload_s, payload_b)
  print("received publish for ", topic)
  aussentemperatur=real(payload_s)
  persist.aussentemperatur=aussentemperatur
  if(aussentemperatur>18)
    if(umwaelzpumpe.getStatus()==true)
        umwaelzpumpe.stop()
        mischventil.reset()
    end
  else
   if(umwaelzpumpe.getStatus()==false)
     umwaelzpumpe.start()
    end
    updateSetPoint()
    return(false)
  end
end

def handle_topic_kp(topic,idx,payload_s,payload_b)
  print("received new kp")
  Kp=real(payload_s)
  persist.Kp=Kp
  regler.setKp(Kp)
end

def handle_topic_ki(topic,idx,payload_s,payload_b)
  print("received new ki")
  Ki=real(payload_s)
  persist.Ki=Ki
  regler.setKi(Ki)
end

def handle_topic_kd(topic,idx,payload_s,payload_b)
  print("received new kd")
  Kd=real(payload_s)
  persist.Kd=Kd
  regler.setKd(Kd)
end

def handle_topic_tempFaktor(topic,idx,payload_s,payload_b)
  print("received new tempFaktor")
  temperaturFaktor=real(payload_s)
  persist.temperaturFaktor=temperaturFaktor
  updateSetPoint()
end

def handle_topic_temperaturKorrektur(topic,idx,payload_s,payload_b)
  print("received new tempCorrection")
  temperaturKorrektur=real(payload_s)
  persist.temperaturKorrektur=temperaturKorrektur
  updateSetPoint()
end

def handle_topic_nightMode(topic, idx, payload_s, payload_b)
  print("received publish for ", topic)
  if payload_s=='true'
    nightMode=true
  else
    nightMode=false
  end
  persist.nightMode=nightMode
end

def handle_topic_nightShift(topic, idx, payload_s, payload_b)
  print("received publish for ", topic)
  nightShift=real(payload_s)
  persist.nightShift=nightShift
  updateSetPoint()
  return(false)
end

class HeatingSensors
    def json_append()
        if extTempForward == nil || extTempReturn == nil ||
           intTempForward == nil || intTempReturn == nil
            return
        end

        var sensors = {
            "VorlaufExtern": {"Temperature": extTempForward},
            "RuecklaufExtern": {"Temperature": extTempReturn},
            "VorlaufIntern": {"Temperature": intTempForward},
            "RuecklaufIntern": {"Temperature": intTempReturn},
            "Zieltemperatur": {"Temperature": regler.setPoint},
            "Heizungsregler": {"TempSlope": calculateTempSlope() * 60},
            "Mischventil": {"Position": mischventil.getPosition()}
        }

        for name : sensors.keys()
            tasmota.response_append(
                "," + json.dump(name) + ":" + json.dump(sensors[name]))
        end
    end

    def web_sensor()
        if extTempForward == nil || extTempReturn == nil ||
           intTempForward == nil || intTempReturn == nil
            return
        end
        tasmota.web_send_decimal(string.format(
            "{s}Vorlauf Extern korrigiert{m}%.2f &deg;C{e}" +
            "{s}Ruecklauf Extern korrigiert{m}%.2f &deg;C{e}" +
            "{s}Vorlauf Intern korrigiert{m}%.2f &deg;C{e}" +
            "{s}Ruecklauf Intern korrigiert{m}%.2f &deg;C{e}" +
            "{s}Zieltemperatur{m}%.2f &deg;C{e}" +
            "{s}Temperaturtrend{m}%.3f K/min{e}",
            extTempForward, extTempReturn, intTempForward, intTempReturn,
            regler.setPoint, calculateTempSlope() * 60))
    end
end

mqtt.subscribe("Heizung/aussentemperatur", handle_topic_aussentemperatur)
mqtt.subscribe("Heizung/nightmode",handle_topic_nightMode)
mqtt.subscribe("Heizung/kp",handle_topic_kp)
mqtt.subscribe("Heizung/ki",handle_topic_ki)
mqtt.subscribe("Heizung/ks",handle_topic_kd)

mqtt.subscribe("Heizung/tempfactor",handle_topic_tempFaktor)
mqtt.subscribe("Heizung/tempcorrection",handle_topic_temperaturKorrektur)
mqtt.subscribe("Heizung/nightshift",handle_topic_nightShift)

var heatingSensors = HeatingSensors()
tasmota.add_driver(heatingSensors)

regler.setVerbose(true)
mischventil.setMinStep(minStep)
mischventil.setVerbose(true)
updateSetPoint()
setupCronTimers()

controlLoop()

