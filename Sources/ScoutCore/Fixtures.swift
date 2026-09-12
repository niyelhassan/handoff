import Foundation
public enum Fixtures {
    public static func evidence(_ shape: String, root: String = "/tmp/RoutineScoutDemo", now: Date = Date()) -> [Evidence] {
        var result: [Evidence] = []
        let count = shape == "loop" ? 3 : 3
        for run in 0..<count {
            let offset = shape == "loop" ? run*15 : run*180
            let base = now.addingTimeInterval(Double(offset-600))
            func e(_ app: String,_ kind: String,_ label: String,_ details: [String:String] = [:],_ index: Int) {
                result.append(Evidence(Event(app:app,kind:kind,role:kind == "paste" ? "AXTextField" : "AXButton",label:label,context:app == "com.apple.Safari" ? "localhost" : "",instance:digest("\(shape)-\(run)"),time:base.addingTimeInterval(Double(index))),details))
            }
            if shape == "transform" {
                e("com.apple.Safari","file","csv",["path":"\(root)/sales-\(run).csv","csv":"Name,Amount,Unused\n Bea ,$20,x\n Ada ,$10,y\n"],0)
                e("com.apple.iWork.Numbers","click","Open",[:],1)
                e("com.apple.iWork.Numbers","click","Sort",[:],2)
                e("com.apple.iWork.Numbers","export","Export",[:],3)
                e("com.apple.iWork.Numbers","file","csv",["path":"\(root)/clean-\(run).csv","csv":"Name,Amount\nAda,10\nBea,20\n"],4)
            } else if shape == "loop" {
                e("com.apple.iWork.Numbers","copy","Name",["row":"A\(run+2)","text":["Ada","Bea","Cy"][run],"path":"\(root)/people.csv"],0)
                e("com.apple.Safari","paste","Name",["label":"Name","value":["Ada","Bea","Cy"][run]],1)
                e("com.apple.iWork.Numbers","copy","Email",["row":"B\(run+2)","text":"person\(run)@example.test"],2)
                e("com.apple.Safari","paste","Email",["label":"Email","value":"person\(run)@example.test"],3)
                e("com.apple.Safari","submit","Submit",["label":"Submit"],4)
            } else {
                e("com.apple.Safari","copy","Name",["text":["Maple Loft","Oak Studio","Pine House"][run],"url":"http://127.0.0.1:8790/listing/\(run)"],0)
                e("com.apple.iWork.Numbers","paste","Name",["row":"A\(run+2)","document":"Apartment Search"],1)
                e("com.apple.Safari","copy","Price",["text":"\(1200+run*100)","url":"http://127.0.0.1:8790/listing/\(run)"],2)
                e("com.apple.iWork.Numbers","paste","Price",["row":"B\(run+2)","document":"Apartment Search"],3)
            }
        }
        return result
    }
    /// Offline stand-in for the AI judge, used by the local examples and when the network is unavailable.
    public static func judgment(_ shape: String) -> Judgment {
        switch shape {
        case "loop": return Judgment(isRoutine:true,name:"Fill the form from your table",description:"You copied each person’s name and email from Numbers into the same web form and submitted it, three rows in a row.",automatable:true,reason:"Repeated rows into the same form",inputs:[0,2])
        case "transform": return Judgment(isRoutine:true,name:"Clean a downloaded CSV",description:"Each time a sales CSV arrived, you opened it, kept the same columns, sorted it, and exported a clean copy.",automatable:true,reason:"Same cleanup on three downloads",inputs:[0])
        default: return Judgment(isRoutine:true,name:"Collect listing details",description:"You copied the name and price from three listing pages into Apartment Search.",automatable:true,reason:"Same fields from three pages",inputs:[0,2])
        }
    }
    public static func cleanup(root: String) -> Automation {
        Automation(name:"Clean a downloaded CSV",description:"Keep names and amounts, trim spaces, read amounts as numbers, and sort by name. Save a new clean file.",steps:[
            Step(.readCSV,"Read the downloaded table",["path":root+"/sales.csv","output":"sales"]),
            Step(.transformTable,"Keep names and amounts",["table":"sales","action":"keepColumns","column":"","value":"[\"Name\",\"Amount\"]","output":"sales"]),
            Step(.transformTable,"Remove extra spaces",["table":"sales","action":"trim","column":"","value":"","output":"sales"]),
            Step(.transformTable,"Read amounts as numbers",["table":"sales","action":"parseNumbers","column":"Amount","value":"","output":"sales"]),
            Step(.transformTable,"Sort by name",["table":"sales","action":"sort","column":"Name","value":"ascending","output":"sales"]),
            Step(.writeCSV,"Save the clean table",["table":"sales","path":root+"/clean.csv"])
        ])
    }
    public static func collector(root: String) -> Automation {
        Automation(name:"Collect listing details",description:"Read the name and price from the listing and append them to Apartment Search.csv.",steps:[
            Step(.readText,"Read the listing name",["output":"name"],target:Target(app:"com.apple.Safari",role:"AXTextField",label:"Listing name")),
            Step(.readText,"Read the price",["output":"price"],target:Target(app:"com.apple.Safari",role:"AXTextField",label:"Price")),
            Step(.readURL,"Read the listing link",["output":"url"],target:Target(app:"com.apple.Safari")),
            Step(.appendCSV,"Add the listing to Apartment Search",["path":root+"/Apartment Search.csv","columns":"[\"Name\",\"Price\",\"Link\"]","values":"[\"{{name}}\",\"{{price}}\",\"{{url}}\"]"])
        ])
    }
    public static func form(root: String) -> Automation {
        Automation(name:"Fill forms from a table",description:"Read the people table and fill each person's name and email. Ask before submitting each form.",steps:[
            Step(.readCSV,"Read the people table",["path":root+"/people.csv","output":"people"]),
            Step(.forEach,"For each person",["source":"people","item":"row"]),
            Step(.setValue,"Fill the name",["value":"{{row.Name}}"],target:Target(app:"com.apple.Safari",role:"AXTextField",label:"Name")),
            Step(.setValue,"Fill the email",["value":"{{row.Email}}"],target:Target(app:"com.apple.Safari",role:"AXTextField",label:"Email")),
            Step(.ask,"Confirm this form",["message":"Submit the form for {{row.Name}}?"]),
            Step(.click,"Submit the form",target:Target(app:"com.apple.Safari",role:"AXButton",label:"Submit")),
            Step(.endLoop,"Continue to the next person")
        ])
    }
}
