import Foundation

/// The five demo routines. Each has recorded evidence (three repetitions, as the observer would have stored them),
/// an offline judgment, and a reference plan that the local practice pages and files satisfy.
public enum Fixtures {
    public static let shapes = ["loop","transform","collect","pipeline","image"]
    public static func title(_ shape: String) -> String {
        switch shape {
        case "loop": return "New hires into the HR form"
        case "transform": return "Weekly sales export cleanup"
        case "collect": return "Apartment hunt: save each listing"
        case "pipeline": return "Invoice filing by date"
        default: return "Screenshots to web JPEGs"
        }
    }
    public static func evidence(_ shape: String, root: String = "/tmp/RoutineScoutDemo", now: Date = Date()) -> [Evidence] {
        var result: [Evidence] = []
        let today = Runner.dateString(now)
        for run in 0..<3 {
            let offset = shape == "loop" ? run*15 : run*180
            let base = now.addingTimeInterval(Double(offset-600))
            func e(_ app: String,_ kind: String,_ label: String,_ details: [String:String] = [:],_ index: Int, role: String? = nil, instance: String? = nil) {
                let role = role ?? (kind == "paste" ? "AXTextField" : kind == "file" ? (details["extension"] ?? "") : "AXButton")
                result.append(Evidence(Event(app:app,kind:kind,role:role,label:label,context:app == "com.apple.Safari" ? "127.0.0.1" : "",instance:instance ?? digest("\(shape)-\(run)"),time:base.addingTimeInterval(Double(index))),details))
            }
            switch shape {
            case "transform":
                e("com.apple.Safari","file","",["path":"\(root)/sales-\(run).csv","extension":"csv","folder":root,"csv":"Name,Amount,Unused\n Bea ,$20,x\n Ada ,$10,y\n"],0)
                e("com.apple.iWork.Numbers","click","Open",[:],1)
                e("com.apple.iWork.Numbers","click","Sort",[:],2)
                e("com.apple.iWork.Numbers","export","Export",[:],3)
                e("com.apple.iWork.Numbers","file","",["path":"\(root)/sales-\(run)-clean.csv","extension":"csv","folder":root,"csv":"Name,Amount\nAda,10\nBea,20\n"],4)
            case "loop":
                let names = ["Ada","Bea","Cy"]
                e("com.apple.iWork.Numbers","copy","Name",["row":"A\(run+2)","text":names[run],"path":"\(root)/people.csv","document":"people.csv"],0)
                e("com.apple.Safari","paste","Name",["label":"Name","value":names[run],"url":"http://127.0.0.1:8790/form"],1)
                e("com.apple.iWork.Numbers","copy","Email",["row":"B\(run+2)","text":names[run].lowercased()+"@example.test","document":"people.csv"],2)
                e("com.apple.Safari","paste","Email",["label":"Email","value":names[run].lowercased()+"@example.test","url":"http://127.0.0.1:8790/form"],3)
                e("com.apple.Safari","submit","Submit",["label":"Submit","url":"http://127.0.0.1:8790/form"],4)
            case "collect":
                let names = ["Maple Loft · 2BR near Union Square","Oak Studio · sunny top floor","Pine House · 3BR with garden"]
                e("com.apple.Safari","copy","Listing name",["text":names[run],"url":"http://127.0.0.1:8790/listing/\(run)","label":"Listing name"],0,role:"AXTextField")
                e("com.apple.iWork.Numbers","paste","Name",["row":"A\(run+2)","document":"Apartment Search.csv","path":"\(root)/Apartment Search.csv"],1)
                e("com.apple.Safari","copy","Price",["text":"\(1200+run*100)","url":"http://127.0.0.1:8790/listing/\(run)","label":"Price"],2,role:"AXTextField")
                e("com.apple.iWork.Numbers","paste","Price",["row":"B\(run+2)","document":"Apartment Search.csv","path":"\(root)/Apartment Search.csv"],3)
                e("com.apple.iWork.Numbers","paste","Link",["row":"C\(run+2)","document":"Apartment Search.csv","path":"\(root)/Apartment Search.csv","value":"http://127.0.0.1:8790/listing/\(run)"],4)
            case "pipeline":
                let number = 8731+run
                e("com.apple.Safari","click","Download invoice",["url":"http://127.0.0.1:8790/invoice/\(run)"],0)
                e("com.apple.Safari","file","",["path":"\(root)/invoice-\(number).pdf","extension":"pdf","folder":root],1,instance:digest("\(root)/invoice-\(number).pdf"))
                e("com.apple.finder","click","AXRow",[:],2,role:"AXRow",instance:digest("\(root)/invoice-\(number).pdf"))
                e("com.apple.finder","file","",["path":"\(root)/Invoices/\(today)-invoice-\(number).pdf","extension":"pdf","folder":"\(root)/Invoices"],3,instance:digest("\(root)/Invoices/\(today)-invoice-\(number).pdf"))
            default:
                let name = "Screenshot \(today) at 10.0\(run)"
                e("com.apple.finder","file","",["path":"\(root)/\(name).png","extension":"png","folder":root,"pixels":"2880x1800"],0,instance:digest("\(root)/\(name).png"))
                e("com.apple.Preview","click","Adjust Size…",[:],1,role:"AXMenuItem")
                e("com.apple.Preview","paste","Width",["value":"1280"],2)
                e("com.apple.Preview","click","OK",[:],3)
                e("com.apple.Preview","export","Export…",[:],4,role:"AXMenuItem")
                e("com.apple.Preview","file","",["path":"\(root)/Web/\(name).jpg","extension":"jpg","folder":"\(root)/Web","pixels":"1280x800"],5,instance:digest("\(root)/Web/\(name).jpg"))
            }
        }
        return result
    }
    /// Offline stand-in for the AI judge, used by the local examples and when the network is unavailable.
    public static func judgment(_ shape: String) -> Judgment {
        switch shape {
        case "loop": return Judgment(isRoutine:true,name:"Fill the form from your table",description:"You copied each person’s name and email from the people table into the same web form and submitted it, three rows in a row.",automatable:true,reason:"Repeated rows into the same form",inputs:[0,2])
        case "transform": return Judgment(isRoutine:true,name:"Clean a downloaded CSV",description:"Each time a sales CSV arrived, you opened it, kept the same columns, sorted it, and exported a clean copy.",automatable:true,reason:"Same cleanup on three downloads",inputs:[0])
        case "collect": return Judgment(isRoutine:true,name:"Collect listing details",description:"You copied the name, price and link from three listing pages into Apartment Search.",automatable:true,reason:"Same fields from three pages",inputs:[0,2])
        case "pipeline": return Judgment(isRoutine:true,name:"File downloaded invoices",description:"Each downloaded invoice was renamed with today’s date and moved into the Invoices folder.",automatable:true,reason:"Same rename and move on three downloads",inputs:[1])
        default: return Judgment(isRoutine:true,name:"Shrink screenshots for the web",description:"Each new screenshot was resized to 1280 pixels wide and exported as a JPEG into the Web folder.",automatable:true,reason:"Same resize and export on three screenshots",inputs:[0])
        }
    }
    public static func plan(_ shape: String, root: String) -> Automation {
        switch shape {
        case "loop": return form(root:root)
        case "transform": return cleanup(root:root)
        case "collect": return collector(root:root)
        case "pipeline": return invoices(root:root)
        default: return screenshots(root:root)
        }
    }
    public static func cleanup(root: String) -> Automation {
        var a = Automation(name:"Clean a downloaded CSV",description:"Keep names and amounts, trim spaces, read amounts as numbers, and sort by name. Save a new clean file next to the original.",steps:[
            Step(.readCSV,"Read the downloaded table",["path":"{{file}}","output":"sales"]),
            Step(.transformTable,"Keep names and amounts",["table":"sales","action":"keepColumns","column":"","value":"[\"Name\",\"Amount\"]","output":"sales"]),
            Step(.transformTable,"Remove extra spaces",["table":"sales","action":"trim","column":"","value":"","output":"sales"]),
            Step(.transformTable,"Read amounts as numbers",["table":"sales","action":"parseNumbers","column":"Amount","value":"","output":"sales"]),
            Step(.transformTable,"Sort by name",["table":"sales","action":"sort","column":"Name","value":"ascending","output":"sales"]),
            Step(.writeCSV,"Save the clean table",["table":"sales","path":"{{folder}}/{{stem}}-clean.csv"])
        ])
        a.inputs = [Parameter("file",root+"/sales-0.csv")]
        a.suggestedTriggers = [RunTrigger("file",title:"When a CSV arrives in this folder",value:root,app:"csv"),RunTrigger()]
        return a
    }
    public static func collector(root: String) -> Automation {
        var a = Automation(name:"Collect listing details",description:"Read the name and price from the listing page and add them, with the link, to Apartment Search.csv.",steps:[
            Step(.readText,"Read the listing name",["output":"name"],target:Target(app:"com.apple.Safari",role:"AXTextField",label:"Listing name")),
            Step(.readText,"Read the price",["output":"price"],target:Target(app:"com.apple.Safari",role:"AXTextField",label:"Price")),
            Step(.readURL,"Read the listing link",["output":"url"],target:Target(app:"com.apple.Safari")),
            Step(.appendCSV,"Add the listing to Apartment Search",["path":root+"/Apartment Search.csv","columns":"[\"Name\",\"Price\",\"Link\"]","values":"[\"{{name}}\",\"{{price}}\",\"{{url}}\"]"])
        ])
        a.suggestedTriggers = [RunTrigger("context",title:"Offer it when I open a listing page",value:"http://127.0.0.1:8790/listing",app:"com.apple.Safari"),RunTrigger()]
        return a
    }
    public static func form(root: String) -> Automation {
        var a = Automation(name:"Fill forms from a table",description:"Read the people table and fill each person's name and email into the form. Ask before submitting each one.",steps:[
            Step(.readCSV,"Read the people table",["path":root+"/people.csv","output":"people"]),
            Step(.forEach,"For each person",["source":"people","item":"row"]),
            Step(.setValue,"Fill the name",["value":"{{row.Name}}"],target:Target(app:"com.apple.Safari",role:"AXTextField",label:"Name")),
            Step(.setValue,"Fill the email",["value":"{{row.Email}}"],target:Target(app:"com.apple.Safari",role:"AXTextField",label:"Email")),
            Step(.ask,"Confirm this form",["message":"Submit the form for {{row.Name}}?"]),
            Step(.click,"Submit the form",target:Target(app:"com.apple.Safari",role:"AXButton",label:"Submit")),
            Step(.endLoop,"Continue to the next person")
        ])
        a.suggestedTriggers = [RunTrigger("loop",title:"Offer it when I open this form",value:"http://127.0.0.1:8790/form",app:"com.apple.Safari"),RunTrigger()]
        return a
    }
    public static func invoices(root: String) -> Automation {
        var a = Automation(name:"File downloaded invoices",description:"Rename each new invoice with today’s date and move it into the Invoices folder.",steps:[
            Step(.moveFile,"File the invoice with today’s date",["source":"{{file}}","destination":"{{folder}}/Invoices/{{today}}-{{stem}}.pdf"])
        ])
        a.inputs = [Parameter("file",root+"/invoice-8731.pdf")]
        a.suggestedTriggers = [RunTrigger("file",title:"When a PDF arrives in this folder",value:root,app:"pdf"),RunTrigger()]
        return a
    }
    public static func screenshots(root: String) -> Automation {
        var a = Automation(name:"Shrink screenshots for the web",description:"Resize each new screenshot to 1280 pixels wide and save it as a JPEG in the Web folder.",steps:[
            Step(.resizeImage,"Resize and save as JPEG",["source":"{{file}}","destination":"{{folder}}/Web/{{stem}}.jpg","width":"1280","height":"1280"])
        ])
        a.inputs = [Parameter("file",root+"/Screenshot \(Runner.dateString(Date())) at 10.00.png")]
        a.suggestedTriggers = [RunTrigger("file",title:"When a screenshot appears in this folder",value:root,app:"png"),RunTrigger()]
        return a
    }
}
