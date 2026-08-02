#!/usr/bin/env python3
"""Generates locations.json — the gazetteer both quantjobs.py and the Mac app read.

Kept as a generator rather than a hand-edited blob so the compact tables below
stay readable; the JSON it emits is what actually ships.
"""
import json
import sys

# continent -> {country code: country name}
WORLD = {
    "North America": {
        "US": "United States", "CA": "Canada", "MX": "Mexico",
        "CR": "Costa Rica", "PA": "Panama", "GT": "Guatemala",
        "DO": "Dominican Republic", "JM": "Jamaica", "BM": "Bermuda",
    },
    "South America": {
        "BR": "Brazil", "AR": "Argentina", "CL": "Chile", "CO": "Colombia",
        "PE": "Peru", "UY": "Uruguay", "EC": "Ecuador", "VE": "Venezuela",
    },
    "Europe": {
        "GB": "United Kingdom", "IE": "Ireland", "NL": "Netherlands",
        "DE": "Germany", "FR": "France", "CH": "Switzerland", "AT": "Austria",
        "BE": "Belgium", "LU": "Luxembourg", "SE": "Sweden", "NO": "Norway",
        "DK": "Denmark", "FI": "Finland", "IS": "Iceland", "ES": "Spain",
        "PT": "Portugal", "IT": "Italy", "GR": "Greece", "PL": "Poland",
        "CZ": "Czechia", "SK": "Slovakia", "HU": "Hungary", "RO": "Romania",
        "BG": "Bulgaria", "HR": "Croatia", "SI": "Slovenia", "RS": "Serbia",
        "EE": "Estonia", "LV": "Latvia", "LT": "Lithuania", "UA": "Ukraine",
        "MT": "Malta", "CY": "Cyprus", "MC": "Monaco", "GI": "Gibraltar",
    },
    "Asia": {
        "IN": "India", "CN": "China", "HK": "Hong Kong", "TW": "Taiwan",
        "JP": "Japan", "KR": "South Korea", "SG": "Singapore",
        "MY": "Malaysia", "ID": "Indonesia", "TH": "Thailand",
        "VN": "Vietnam", "PH": "Philippines", "IL": "Israel", "AE": "UAE",
        "SA": "Saudi Arabia", "QA": "Qatar", "TR": "Turkey", "PK": "Pakistan",
        "BD": "Bangladesh", "LK": "Sri Lanka", "KZ": "Kazakhstan",
        "GE": "Georgia", "AM": "Armenia", "JO": "Jordan", "BH": "Bahrain",
    },
    "Africa": {
        "ZA": "South Africa", "NG": "Nigeria", "KE": "Kenya", "EG": "Egypt",
        "MA": "Morocco", "GH": "Ghana", "TN": "Tunisia", "ET": "Ethiopia",
        "RW": "Rwanda", "MU": "Mauritius",
    },
    "Oceania": {
        "AU": "Australia", "NZ": "New Zealand", "FJ": "Fiji",
    },
}

# Extra spellings a board might use. ISO3 and the plain name are added below.
ALIASES = {
    "US": ["usa", "u.s.", "u.s.a.", "united states of america", "america",
           "united states of america (usa)"],
    "GB": ["uk", "u.k.", "great britain", "britain", "england", "scotland",
           "wales", "northern ireland"],
    "AE": ["united arab emirates"],
    "KR": ["korea", "republic of korea", "south korea"],
    "HK": ["hong kong sar", "hong kong s.a.r."],
    "TW": ["taiwan, china", "chinese taipei"],
    "CZ": ["czech republic"],
    "NL": ["the netherlands", "holland"],
    "CN": ["people's republic of china", "prc", "mainland china"],
    "RU": ["russian federation"],
}

ISO3 = {
    "US": "USA", "CA": "CAN", "MX": "MEX", "BR": "BRA", "AR": "ARG",
    "CL": "CHL", "CO": "COL", "PE": "PER", "UY": "URY", "GB": "GBR",
    "IE": "IRL", "NL": "NLD", "DE": "DEU", "FR": "FRA", "CH": "CHE",
    "AT": "AUT", "BE": "BEL", "LU": "LUX", "SE": "SWE", "NO": "NOR",
    "DK": "DNK", "FI": "FIN", "ES": "ESP", "PT": "PRT", "IT": "ITA",
    "GR": "GRC", "PL": "POL", "CZ": "CZE", "SK": "SVK", "HU": "HUN",
    "RO": "ROU", "BG": "BGR", "HR": "HRV", "SI": "SVN", "RS": "SRB",
    "EE": "EST", "LV": "LVA", "LT": "LTU", "UA": "UKR", "IN": "IND",
    "CN": "CHN", "HK": "HKG", "TW": "TWN", "JP": "JPN", "KR": "KOR",
    "SG": "SGP", "MY": "MYS", "ID": "IDN", "TH": "THA", "VN": "VNM",
    "PH": "PHL", "IL": "ISR", "AE": "ARE", "SA": "SAU", "QA": "QAT",
    "TR": "TUR", "PK": "PAK", "ZA": "ZAF", "NG": "NGA", "KE": "KEN",
    "EG": "EGY", "MA": "MAR", "GH": "GHA", "AU": "AUS", "NZ": "NZL",
    "CR": "CRI", "PA": "PAN", "IS": "ISL", "MT": "MLT", "CY": "CYP",
}

US_STATES = {
    "al": "Alabama", "ak": "Alaska", "az": "Arizona", "ar": "Arkansas",
    "ca": "California", "co": "Colorado", "ct": "Connecticut",
    "de": "Delaware", "fl": "Florida", "ga": "Georgia", "hi": "Hawaii",
    "id": "Idaho", "il": "Illinois", "in": "Indiana", "ia": "Iowa",
    "ks": "Kansas", "ky": "Kentucky", "la": "Louisiana", "me": "Maine",
    "md": "Maryland", "ma": "Massachusetts", "mi": "Michigan",
    "mn": "Minnesota", "ms": "Mississippi", "mo": "Missouri",
    "mt": "Montana", "ne": "Nebraska", "nv": "Nevada",
    "nh": "New Hampshire", "nj": "New Jersey", "nm": "New Mexico",
    "ny": "New York", "nc": "North Carolina", "nd": "North Dakota",
    "oh": "Ohio", "ok": "Oklahoma", "or": "Oregon", "pa": "Pennsylvania",
    "ri": "Rhode Island", "sc": "South Carolina", "sd": "South Dakota",
    "tn": "Tennessee", "tx": "Texas", "ut": "Utah", "vt": "Vermont",
    "va": "Virginia", "wa": "Washington", "wv": "West Virginia",
    "wi": "Wisconsin", "wy": "Wyoming", "dc": "District of Columbia",
}

CA_PROVINCES = {
    "on": "Ontario", "qc": "Quebec", "bc": "British Columbia",
    "ab": "Alberta", "mb": "Manitoba", "sk": "Saskatchewan",
    "ns": "Nova Scotia", "nb": "New Brunswick", "nl": "Newfoundland",
}

# country code -> cities
CITIES = {
    "US": [
        "New York", "New York City", "NYC", "Brooklyn", "Manhattan",
        "Jersey City", "Newark", "Hoboken", "Princeton", "Stamford",
        "Greenwich", "Hartford", "White Plains", "Purchase", "Armonk",
        "Long Island City", "Chicago", "Evanston", "Boston", "Cambridge",
        "Somerville", "Waltham", "Burlington", "Lexington", "Needham",
        "San Francisco", "South San Francisco", "Palo Alto", "Mountain View",
        "Menlo Park", "Sunnyvale", "Santa Clara", "San Jose", "Cupertino",
        "Redwood City", "Foster City", "San Mateo", "Oakland", "Berkeley",
        "Fremont", "Milpitas", "Emeryville", "Los Altos", "Campbell",
        "Los Angeles", "Santa Monica", "Culver City", "El Segundo",
        "Costa Mesa", "Irvine", "Pasadena", "Long Beach", "Torrance",
        "Santa Barbara", "San Diego", "Carlsbad", "Sacramento",
        "Seattle", "Bellevue", "Redmond", "Kirkland", "Bothell",
        "Portland", "Beaverton", "Hillsboro", "Austin", "Dallas", "Plano",
        "Houston", "San Antonio", "Denver", "Boulder", "Fort Collins",
        "Longmont", "Atlanta", "Alpharetta", "Miami", "Tampa", "Orlando",
        "Jacksonville", "Washington", "Washington DC", "Arlington",
        "Reston", "McLean", "Herndon", "Bethesda", "Baltimore", "Columbia",
        "Philadelphia", "Pittsburgh", "Bala Cynwyd", "Minneapolis",
        "Detroit", "Ann Arbor", "Columbus", "Cincinnati", "Cleveland",
        "Nashville", "Charlotte", "Raleigh", "Durham", "Phoenix", "Tempe",
        "Chandler", "Scottsdale", "Salt Lake City", "Lehi", "Las Vegas",
        "Boise", "Madison", "Milwaukee", "St. Louis", "Kansas City",
        "Indianapolis", "Richmond", "New Orleans", "Folsom", "Roseville",
        "Santa Cruz", "Mountain Brook", "Provo", "Omaha", "Des Moines",
        "Rochester", "Buffalo", "Albany", "Syracuse", "Ithaca", "Princeton",
    ],
    "CA": ["Toronto", "Vancouver", "Montreal", "Ottawa", "Waterloo",
           "Kitchener", "Calgary", "Edmonton", "Quebec City", "Mississauga",
           "Markham", "Burnaby", "Victoria", "Halifax", "Winnipeg"],
    "MX": ["Mexico City", "Guadalajara", "Monterrey", "Queretaro", "Tijuana"],
    "CR": ["San Jose, Costa Rica", "Heredia"],
    "BR": ["Sao Paulo", "São Paulo", "Rio de Janeiro", "Belo Horizonte",
           "Porto Alegre", "Campinas", "Recife", "Florianopolis", "Curitiba"],
    "AR": ["Buenos Aires", "Cordoba", "Rosario"],
    "CL": ["Santiago"], "CO": ["Bogota", "Bogotá", "Medellin", "Medellín"],
    "PE": ["Lima"], "UY": ["Montevideo"],
    "GB": ["London", "Oxford", "Manchester", "Edinburgh", "Bristol", "Leeds",
           "Glasgow", "Belfast", "Reading", "Birmingham", "Cardiff",
           "Newcastle", "Sheffield", "Nottingham", "Brighton", "Guildford",
           "Milton Keynes", "Slough", "Cheltenham", "Warrington"],
    "IE": ["Dublin", "Cork", "Galway", "Limerick"],
    "NL": ["Amsterdam", "Rotterdam", "Eindhoven", "Utrecht", "The Hague",
           "Nijmegen", "Delft", "Groningen", "Hoofddorp"],
    "DE": ["Berlin", "Munich", "München", "Frankfurt", "Hamburg", "Dresden",
           "Stuttgart", "Cologne", "Köln", "Düsseldorf", "Dusseldorf",
           "Karlsruhe", "Aachen", "Nuremberg", "Leipzig", "Hannover",
           "Bonn", "Mannheim", "Freiburg", "Ulm", "Regensburg"],
    "FR": ["Paris", "Lyon", "Toulouse", "Grenoble", "Sophia Antipolis",
           "Nice", "Bordeaux", "Nantes", "Lille", "Marseille", "Rennes",
           "Montpellier", "Strasbourg"],
    "CH": ["Zurich", "Zürich", "Zug", "Geneva", "Genève", "Lausanne",
           "Basel", "Bern", "Lugano", "Winterthur"],
    "AT": ["Vienna", "Wien", "Graz", "Linz", "Salzburg"],
    "BE": ["Brussels", "Antwerp", "Ghent", "Leuven"],
    "LU": ["Luxembourg City"],
    "SE": ["Stockholm", "Gothenburg", "Göteborg", "Lund", "Malmo", "Malmö",
           "Uppsala", "Linköping"],
    "NO": ["Oslo", "Trondheim", "Bergen"],
    "DK": ["Copenhagen", "København", "Aarhus"],
    "FI": ["Helsinki", "Espoo", "Tampere", "Oulu"],
    "ES": ["Madrid", "Barcelona", "Valencia", "Malaga", "Málaga", "Seville",
           "Bilbao", "Zaragoza"],
    "PT": ["Lisbon", "Lisboa", "Porto", "Braga", "Coimbra"],
    "IT": ["Milan", "Milano", "Rome", "Roma", "Turin", "Torino", "Bologna",
           "Naples", "Florence", "Pisa", "Catania"],
    "GR": ["Athens", "Thessaloniki", "Patras"],
    "PL": ["Warsaw", "Warszawa", "Krakow", "Kraków", "Wroclaw", "Wrocław",
           "Gdansk", "Gdańsk", "Poznan", "Poznań", "Lodz", "Katowice"],
    "CZ": ["Prague", "Praha", "Brno", "Ostrava"],
    "SK": ["Bratislava", "Kosice"], "HU": ["Budapest", "Debrecen", "Szeged"],
    "RO": ["Bucharest", "București", "Cluj", "Cluj-Napoca", "Iasi", "Iași",
           "Timisoara", "Timișoara", "Brasov"],
    "BG": ["Sofia", "Plovdiv", "Varna"],
    "HR": ["Zagreb", "Split"], "SI": ["Ljubljana"],
    "RS": ["Belgrade", "Novi Sad", "Nis"],
    "EE": ["Tallinn", "Tartu"], "LV": ["Riga"],
    "LT": ["Vilnius", "Kaunas"],
    "UA": ["Kyiv", "Kiev", "Lviv", "Kharkiv", "Odesa"],
    "MT": ["Valletta", "Sliema"], "CY": ["Nicosia", "Limassol"],
    "IN": ["Bangalore", "Bengaluru", "Hyderabad", "Pune", "Chennai",
           "Mumbai", "Delhi", "New Delhi", "Gurgaon", "Gurugram", "Noida",
           "Kolkata", "Ahmedabad", "Trivandrum", "Thiruvananthapuram",
           "Kochi", "Coimbatore", "Jaipur", "Indore", "Chandigarh",
           "Bhubaneswar", "Mysore", "Vadodara", "Nagpur"],
    "CN": ["Beijing", "Shanghai", "Shenzhen", "Hangzhou", "Guangzhou",
           "Chengdu", "Nanjing", "Suzhou", "Wuhan", "Xi'an", "Tianjin",
           "Dalian", "Qingdao", "Xiamen", "Zhuhai"],
    "HK": ["Hong Kong", "Kowloon", "Central"],
    "TW": ["Taipei", "Hsinchu", "Taichung", "Tainan", "Kaohsiung"],
    "JP": ["Tokyo", "Osaka", "Yokohama", "Kyoto", "Nagoya", "Fukuoka",
           "Sapporo", "Kobe", "Kawasaki"],
    "KR": ["Seoul", "Busan", "Incheon", "Pangyo", "Seongnam", "Daejeon"],
    "SG": ["Singapore"],
    "MY": ["Kuala Lumpur", "Penang", "Cyberjaya", "Johor Bahru"],
    "ID": ["Jakarta", "Bandung", "Surabaya"],
    "TH": ["Bangkok", "Chiang Mai"],
    "VN": ["Ho Chi Minh City", "Hanoi", "Da Nang", "Saigon"],
    "PH": ["Manila", "Cebu", "Taguig", "Makati", "Quezon City"],
    "IL": ["Tel Aviv", "Tel Aviv-Yafo", "Tel-Aviv", "Haifa", "Jerusalem",
           "Herzliya", "Ra'anana", "Raanana", "Netanya", "Yokneam",
           "Petah Tikva", "Rehovot", "Beer Sheva"],
    "AE": ["Dubai", "Abu Dhabi"], "SA": ["Riyadh", "Jeddah", "Dhahran"],
    "QA": ["Doha"], "BH": ["Manama"], "JO": ["Amman"],
    "TR": ["Istanbul", "Ankara", "Izmir"],
    "PK": ["Karachi", "Lahore", "Islamabad"],
    "BD": ["Dhaka"], "LK": ["Colombo"], "GE": ["Tbilisi"], "AM": ["Yerevan"],
    "KZ": ["Almaty", "Astana"],
    "ZA": ["Cape Town", "Johannesburg", "Durban", "Pretoria", "Sandton"],
    "NG": ["Lagos", "Abuja"], "KE": ["Nairobi"],
    "EG": ["Cairo", "Alexandria"], "MA": ["Casablanca", "Rabat"],
    "GH": ["Accra"], "TN": ["Tunis"], "RW": ["Kigali"], "MU": ["Port Louis"],
    "ET": ["Addis Ababa"],
    "AU": ["Sydney", "Melbourne", "Brisbane", "Perth", "Adelaide",
           "Canberra", "Gold Coast"],
    "NZ": ["Auckland", "Wellington", "Christchurch"],
}

REMOTE_TERMS = ["remote", "anywhere", "virtual", "work from home",
                "distributed", "remote - us", "remote (us)", "fully remote",
                "home based", "telecommute"]

# Phrases that are not places at all — boards use them as filler.
NOISE = ["multiple locations", "various", "tbd", "n/a", "flexible",
         "worldwide", "global", "any office", "all locations", "unspecified",
         "hq", "headquarters", "office", "on-site", "onsite", "hybrid"]


def build():
    countries, aliases = {}, {}
    for continent, members in WORLD.items():
        for code, name in members.items():
            countries[code] = {"name": name, "continent": continent}
            aliases[name.lower()] = code
            aliases[code.lower()] = code
            if code in ISO3:
                aliases[ISO3[code].lower()] = code
            for extra in ALIASES.get(code, []):
                aliases[extra] = code

    regions = {}
    for abbr, name in US_STATES.items():
        regions[abbr] = {"country": "US", "name": name}
        regions[name.lower()] = {"country": "US", "name": name}
    for abbr, name in CA_PROVINCES.items():
        regions[abbr] = {"country": "CA", "name": name}
        regions[name.lower()] = {"country": "CA", "name": name}

    cities = {}
    for code, names in CITIES.items():
        for raw in names:
            # "San Jose, Costa Rica" is a disambiguating label, not a key.
            key = raw.split(",")[0].strip().lower()
            display = raw.split(",")[0].strip()
            cities.setdefault(key, {"name": display, "country": code})

    return {
        "_comment": [
            "Gazetteer shared by quantjobs.py and the Mac app.",
            "Regenerate with the builder rather than editing by hand.",
            "countryAliases maps any spelling a board might use to an ISO2 code.",
            "A city only sets the country when the string names no country itself,",
            "so 'Dublin, IRL' stays Irish and 'Dublin, OH' stays American.",
        ],
        "countries": countries,
        "countryAliases": aliases,
        "regions": regions,
        "cities": cities,
        "remoteTerms": REMOTE_TERMS,
        "noiseTerms": NOISE,
    }


if __name__ == "__main__":
    data = build()
    out = sys.argv[1] if len(sys.argv) > 1 else "locations.json"
    with open(out, "w") as f:
        json.dump(data, f, indent=1, sort_keys=True, ensure_ascii=False)
    print(f"{len(data['countries'])} countries, {len(data['cities'])} cities, "
          f"{len(data['regions'])} regions → {out}")
