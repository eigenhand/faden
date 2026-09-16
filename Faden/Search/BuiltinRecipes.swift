import Foundation

/// Ready-made recipes for the usual suspects. They are ordinary recipes — nothing
/// here is privileged, and each one is editable in the settings just like a
/// synthesised one. The app ships no keys and no default provider.
enum BuiltinRecipes {

    static var all: [SearchRecipe] { [brave, tavily, serper, searxng, exa, blank] }

    static var brave: SearchRecipe {
        var r = SearchRecipe()
        r.name = "Brave Search"
        r.method = .get
        r.url = "https://api.search.brave.com/res/v1/web/search"
        r.queryParamName = "q"
        r.staticQueryItems = ["count": "{{count}}"]
        r.authStyle = .header(name: "X-Subscription-Token", valueTemplate: "{{key}}")
        // No Accept-Encoding here on purpose: URLSession negotiates and decompresses
        // transparently, and setting it by hand suppresses that — the body then
        // arrives as raw gzip bytes and never parses as JSON.
        r.headers = ["Accept": "application/json"]
        r.resultsPath = "web.results"
        r.titleKey = "title"
        r.urlKey = "url"
        r.snippetKey = "description"
        r.dateKey = "age"
        // Brave returns a short teaser plus several longer passages, and separates
        // timely hits into their own list. Both were being thrown away.
        r.extraTextKey = "extra_snippets"
        r.sourceKey = "profile.name"
        r.additionalResultPaths = ["news.results"]
        r.isBuiltIn = true
        return r
    }

    static var tavily: SearchRecipe {
        var r = SearchRecipe()
        r.name = "Tavily"
        r.method = .post
        r.url = "https://api.tavily.com/search"
        r.queryParamName = nil
        r.authStyle = .header(name: "Authorization", valueTemplate: "Bearer {{key}}")
        r.headers = ["Content-Type": "application/json"]
        r.bodyTemplate = #"{"query":"{{query}}","max_results":{{count}},"include_answer":true}"#
        r.resultsPath = "results"
        r.titleKey = "title"
        r.urlKey = "url"
        r.snippetKey = "content"
        r.answerPath = "answer"
        r.dateKey = "published_date"
        r.isBuiltIn = true
        return r
    }

    static var serper: SearchRecipe {
        var r = SearchRecipe()
        r.name = "Serper (Google)"
        r.method = .post
        r.url = "https://google.serper.dev/search"
        r.queryParamName = nil
        r.authStyle = .header(name: "X-API-KEY", valueTemplate: "{{key}}")
        r.headers = ["Content-Type": "application/json"]
        r.bodyTemplate = #"{"q":"{{query}}","num":{{count}}}"#
        r.resultsPath = "organic"
        r.titleKey = "title"
        r.urlKey = "link"
        r.snippetKey = "snippet"
        r.dateKey = "date"
        r.isBuiltIn = true
        return r
    }

    static var searxng: SearchRecipe {
        var r = SearchRecipe()
        r.name = "SearXNG (eigene Instanz)"
        r.method = .get
        r.url = "https://searx.example.org/search"
        r.queryParamName = "q"
        r.staticQueryItems = ["format": "json"]
        r.authStyle = .none
        r.headers = ["Accept": "application/json"]
        r.resultsPath = "results"
        r.titleKey = "title"
        r.urlKey = "url"
        r.snippetKey = "content"
        r.isBuiltIn = true
        return r
    }

    static var exa: SearchRecipe {
        var r = SearchRecipe()
        r.name = "Exa"
        r.method = .post
        r.url = "https://api.exa.ai/search"
        r.queryParamName = nil
        r.authStyle = .header(name: "x-api-key", valueTemplate: "{{key}}")
        r.headers = ["Content-Type": "application/json"]
        r.bodyTemplate = #"{"query":"{{query}}","numResults":{{count}},"contents":{"text":{"maxCharacters":600}}}"#
        r.resultsPath = "results"
        r.titleKey = "title"
        r.urlKey = "url"
        r.snippetKey = "text"
        r.dateKey = "publishedDate"
        r.isBuiltIn = true
        return r
    }

    /// The starting point for anything not listed — fill in URL and key, then let
    /// the auto-configuration work out the rest.
    static var blank: SearchRecipe {
        var r = SearchRecipe()
        r.name = "Eigener Anbieter"
        r.method = .get
        r.url = ""
        r.queryParamName = "q"
        r.authStyle = .header(name: "Authorization", valueTemplate: "Bearer {{key}}")
        r.headers = ["Accept": "application/json"]
        r.resultsPath = ""
        return r
    }
}
