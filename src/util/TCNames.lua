-- Name styles for new workers and administrators: the nameStyle setting
-- picks one, or a mix. A name's first name and surname always come from
-- the same style, so nobody's half French and half Polish.
--
-- First names are by gender (041), so the name matches the look in the cab.
-- A surname is a string, or { male = ..., female = ... } where it changes
-- with gender (Polish -ski/-ska).
--
-- Adding a style: a STYLES entry, its key in TheContractorSettings.NAME_STYLES
-- (at the end, as saves keep the option's number) and a tc_nameStyle_<key>
-- l10n key. Add it to MIXES.european too if it's European.

TCNames = {}

TCNames.STYLES = {
    british = {
        male = {
            "James", "John", "Robert", "Michael", "David", "Daniel", "Thomas", "Peter", "Mark", "Paul",
            "Andrew", "Richard", "William", "George", "Harry", "Jack", "Oliver", "Charlie", "Alfie", "Henry",
            "Edward", "Samuel", "Joseph", "Matthew", "Christopher", "Stephen", "Simon", "Ian", "Gareth", "Rhys",
            "Owen", "Callum", "Jamie", "Liam", "Ben", "Tom", "Adam", "Luke", "Nathan", "Ryan",
            "Craig", "Stuart", "Graham", "Neil", "Alan", "Colin", "Dean", "Lewis", "Steve", "Joe", "Mike"
        },
        female = {
            "Mary", "Sarah", "Emma", "Olivia", "Sophie", "Grace", "Amy", "Laura", "Hannah", "Rachel",
            "Lucy", "Kate", "Charlotte", "Emily", "Jessica", "Rebecca", "Chloe", "Ellie", "Megan", "Holly",
            "Isla", "Freya", "Poppy", "Alice", "Jane", "Helen", "Claire", "Karen", "Susan", "Joanne",
            "Nicola", "Gemma", "Victoria", "Katie", "Lauren", "Amelia", "Ruby", "Bethan", "Rhiannon", "Fiona",
            "Kirsty", "Eilidh", "Harriet", "Abigail",
        },
        surnames = {
            "Smith", "Jones", "Taylor", "Brown", "Wilson", "Evans", "Walker", "White", "Roberts", "Green",
            "Hall", "Wood", "Baker", "Clarke", "Turner", "Hughes", "Williams", "Davies", "Johnson", "Thompson",
            "Wright", "Robinson", "Edwards", "Lewis", "Harris", "Jackson", "Lee", "Cooper", "Hill", "Ward",
            "Morris", "Moore", "King", "Harrison", "Morgan", "Allen", "Scott", "Young", "Mitchell", "Watson",
            "Price", "Bennett", "Griffiths", "Fletcher", "Shaw", "Carter", "Phillips", "Holmes", "Marshall", "Fisher",
            "Mason", "Parker", "Cartwright", "Hobbs", "Pritchard", "MacDonald", "Campbell", "Stewart", "Fraser", "Reid",
        },
    },

    irish = {
        male = {
            "Seán", "Patrick", "Liam", "Conor", "Ciarán", "Cian", "Darragh", "Eoin", "Niall", "Declan",
            "Colm", "Brendan", "Fergal", "Kevin", "Aidan", "Donal", "Cathal", "Oisín", "Ronan", "Shane",
            "Diarmuid", "Tadhg", "Pádraig", "Michael", "John", "Brian", "Dermot", "Finbar", "Fionn", "Rory",
            "Dara", "Kieran", "Eamon", "Paddy", "Cormac", "Barry",
        },
        female = {
            "Aoife", "Siobhán", "Niamh", "Sinéad", "Ciara", "Orla", "Áine", "Róisín", "Caoimhe", "Clodagh",
            "Saoirse", "Gráinne", "Éabha", "Deirdre", "Bríd", "Maeve", "Aisling", "Nuala", "Eimear", "Sorcha",
            "Mairéad", "Úna", "Catherine", "Bridget", "Mary", "Sheila", "Emer", "Laoise", "Muireann", "Ailbhe",
            "Orlaith", "Kate",
        },
        surnames = {
            "Murphy", "Kelly", "O'Sullivan", "Walsh", "O'Brien", "Byrne", "Ryan", "O'Connor", "O'Neill", "O'Reilly",
            "Doyle", "McCarthy", "Gallagher", "O'Doherty", "Kennedy", "Lynch", "Murray", "Quinn", "McLoughlin", "Carroll",
            "Connolly", "Daly", "O'Connell", "Dunne", "Brennan", "Burke", "Collins", "Farrell", "Fitzgerald", "Maguire",
            "Nolan", "Flynn", "Callaghan", "O'Donnell", "Duffy", "O'Mahony", "Boyle", "Healy", "O'Shea", "Whelan",
            "Sheehan", "Hogan", "Keane", "Power", "Cullen", "Kavanagh", "Hayes", "Foley", "McGrath", "Regan",
            "Donnelly", "Dolan",
        },
    },

    american = {
        male = {
            "James", "Michael", "Robert", "John", "William", "David", "Joseph", "Charles", "Christopher", "Daniel",
            "Matthew", "Anthony", "Joshua", "Andrew", "Ryan", "Tyler", "Brandon", "Justin", "Kyle", "Cody",
            "Austin", "Dustin", "Travis", "Wyatt", "Hunter", "Colton", "Garrett", "Brett", "Chase", "Logan",
            "Mason", "Ethan", "Caleb", "Jacob", "Dale", "Wayne", "Earl", "Clayton", "Hank", "Bobby",
            "Jesse", "Luke",
        },
        female = {
            "Jennifer", "Jessica", "Ashley", "Amanda", "Brittany", "Megan", "Lauren", "Taylor", "Madison", "Kayla",
            "Emily", "Hannah", "Abigail", "Brooke", "Savannah", "Hailey", "Kaylee", "Morgan", "Courtney", "Tiffany",
            "Crystal", "Amber", "Heather", "Melissa", "Kimberly", "Stephanie", "Nicole", "Samantha", "Mackenzie", "Paige",
            "Shelby", "Carly", "Dakota", "Peyton", "Avery", "Harper", "Addison", "Riley", "Becky", "Darlene",
        },
        surnames = {
            "Smith", "Johnson", "Williams", "Brown", "Jones", "Miller", "Davis", "Garcia", "Rodriguez", "Wilson",
            "Martinez", "Anderson", "Taylor", "Thomas", "Hernandez", "Moore", "Martin", "Jackson", "Thompson", "White",
            "Lopez", "Harris", "Clark", "Lewis", "Robinson", "Walker", "Young", "Allen", "Wright", "Hill",
            "Scott", "Adams", "Baker", "Nelson", "Carter", "Mitchell", "Roberts", "Turner", "Phillips", "Parker",
            "Collins", "Stewart", "Cook", "Rogers", "Peterson", "Reed", "Bailey", "Bell", "Howard", "Cox",
            "Richardson", "Brooks", "Gray", "Sanders", "Barnes", "Henderson", "Coleman", "Jenkins", "Perry", "Powell",
            "Patterson", "Schultz", "Olson", "Hansen", "Larson",
        },
    },

    french = {
        male = {
            "Jean", "Pierre", "Michel", "Philippe", "Alain", "Nicolas", "François", "Laurent", "Christophe", "Stéphane",
            "Olivier", "Julien", "Sébastien", "Thomas", "Antoine", "Mathieu", "Guillaume", "Romain", "Maxime", "Hugo",
            "Lucas", "Louis", "Gabriel", "Arthur", "Jules", "Raphaël", "Théo", "Baptiste", "Benoît", "Didier",
            "Thierry", "Yves", "Patrick", "Bernard", "Gérard", "Jacques", "Henri", "Rémi", "Clément", "Étienne",
        },
        female = {
            "Marie", "Nathalie", "Isabelle", "Sylvie", "Catherine", "Françoise", "Valérie", "Sandrine", "Céline", "Sophie",
            "Julie", "Aurélie", "Camille", "Chloé", "Léa", "Manon", "Emma", "Inès", "Jade", "Louise",
            "Alice", "Juliette", "Margaux", "Pauline", "Mathilde", "Élodie", "Amandine", "Claire", "Hélène", "Brigitte",
            "Monique", "Martine", "Christine", "Anne", "Lucie", "Océane", "Clémence", "Agathe", "Élise", "Charlotte",
        },
        surnames = {
            "Martin", "Bernard", "Dubois", "Robert", "Richard", "Petit", "Durand", "Leroy", "Moreau", "Simon",
            "Laurent", "Lefebvre", "Michel", "Bertrand", "Roux", "Vincent", "Fournier", "Morel", "Girard", "André",
            "Lefèvre", "Mercier", "Dupont", "Lambert", "Bonnet", "Legrand", "Garnier", "Faure", "Rousseau", "Blanc",
            "Guérin", "Henry", "Roussel", "Perrin", "Morin", "Mathieu", "Gauthier", "Dumont", "Fontaine", "Chevalier",
            "Robin", "Masson", "Boyer", "Denis", "Lemaire", "Duval", "Joly", "Roche", "Roy", "Noël",
            "Meunier", "Marchand", "Barbier", "Brun", "Picard",
        },
    },

    german = {
        male = {
            "Lukas", "Jonas", "Leon", "Finn", "Felix", "Maximilian", "Paul", "Elias", "Ben", "Noah",
            "Tim", "Jan", "Tobias", "Florian", "Stefan", "Michael", "Thomas", "Andreas", "Markus", "Christian",
            "Matthias", "Sebastian", "Daniel", "Alexander", "Martin", "Jürgen", "Klaus", "Wolfgang", "Dieter", "Uwe",
            "Helmut", "Günter", "Manfred", "Karl", "Heinz", "Johannes", "Fabian", "Niklas", "Moritz", "Jakob",
        },
        female = {
            "Anna", "Lena", "Lea", "Hannah", "Mia", "Emma", "Sophie", "Marie", "Laura", "Julia",
            "Sarah", "Katharina", "Lisa", "Johanna", "Leonie", "Clara", "Charlotte", "Greta", "Paula", "Ida",
            "Sabine", "Petra", "Monika", "Ursula", "Andrea", "Claudia", "Birgit", "Heike", "Susanne", "Karin",
            "Gisela", "Renate", "Stefanie", "Nicole", "Melanie", "Franziska", "Anja", "Christina", "Lina", "Frieda",
        },
        surnames = {
            "Müller", "Schmidt", "Schneider", "Fischer", "Weber", "Meyer", "Wagner", "Becker", "Schulz", "Hoffmann",
            "Schäfer", "Koch", "Bauer", "Richter", "Klein", "Wolf", "Schröder", "Neumann", "Schwarz", "Zimmermann",
            "Braun", "Krüger", "Hartmann", "Lange", "Schmitt", "Werner", "Schmitz", "Krause", "Meier", "Lehmann",
            "Schulze", "Maier", "Köhler", "Herrmann", "König", "Walter", "Huber", "Kaiser", "Fuchs", "Peters",
            "Scholz", "Möller", "Weiß", "Jung", "Hahn", "Schubert", "Vogel", "Friedrich", "Keller", "Günther",
            "Berger", "Winkler", "Roth", "Beck", "Lorenz", "Baumann", "Franke", "Albrecht", "Brandt", "Bergmann",
            "Pohl", "Engel",
        },
    },

    dutch = {
        male = {
            "Jan", "Pieter", "Kees", "Henk", "Willem", "Dirk", "Joost", "Bram", "Daan", "Sem",
            "Lars", "Thijs", "Ruben", "Jeroen", "Bas", "Sander", "Martijn", "Niels", "Wouter", "Maarten",
            "Koen", "Tom", "Jasper", "Stijn", "Gerrit", "Hendrik", "Johan", "Erik", "Frank", "Rob",
            "Arjen", "Teun", "Luuk", "Jesse", "Milan", "Tim", "Floris", "Sjoerd", "Hidde", "Wim",
        },
        female = {
            "Anna", "Emma", "Sophie", "Julia", "Tess", "Sanne", "Lotte", "Fleur", "Femke", "Anouk",
            "Lieke", "Eva", "Iris", "Noor", "Saar", "Fenna", "Roos", "Esther", "Marieke", "Ingrid",
            "Annemiek", "Petra", "Ellen", "Monique", "Karin", "Wilma", "Joke", "Ria", "Mieke", "Linda",
            "Daphne", "Merel", "Ilse", "Marloes", "Inge", "Bregje", "Nienke", "Maud", "Isa", "Jet",
        },
        surnames = {
            "de Jong", "Jansen", "de Vries", "van den Berg", "van Dijk", "Bakker", "Janssen", "Visser", "Smit", "Meijer",
            "de Boer", "Mulder", "de Groot", "Bos", "Vos", "Peters", "Hendriks", "van Leeuwen", "Dekker", "Brouwer",
            "de Wit", "Dijkstra", "Smits", "de Graaf", "van der Meer", "van der Linden", "Kok", "Jacobs", "de Haan", "Vermeulen",
            "van den Heuvel", "van der Veen", "van den Broek", "de Bruijn", "van der Heijden", "Schouten", "van Beek", "Willems", "van Vliet", "van de Ven",
            "Hoekstra", "Maas", "Verhoeven", "Koster", "van Dam", "van der Wal", "Prins", "Blom", "Huisman", "de Lange",
            "Kuipers", "Veenstra", "Postma", "Bosman",
        },
    },

    scandinavian = {
        male = {
            "Lars", "Anders", "Erik", "Johan", "Nils", "Magnus", "Henrik", "Mikkel", "Rasmus", "Søren",
            "Jens", "Ole", "Knut", "Bjørn", "Sven", "Olav", "Fredrik", "Gustav", "Axel", "Oskar",
            "Emil", "Jonas", "Mads", "Kasper", "Per", "Ingvar", "Leif", "Torbjørn", "Sigurd", "Håkon",
            "Arne", "Kristian", "Mathias", "Elias", "Viktor", "Isak", "Linus", "Tor", "Stig", "Einar",
        },
        female = {
            "Anna", "Ingrid", "Astrid", "Sigrid", "Karin", "Kristin", "Maja", "Elsa", "Freja", "Ida",
            "Emma", "Ebba", "Alma", "Wilma", "Saga", "Liv", "Signe", "Sofie", "Mette", "Lene",
            "Hanne", "Birgitte", "Camilla", "Malin", "Linnea", "Johanna", "Frida", "Nora", "Ingeborg", "Solveig",
            "Eva", "Kari", "Marit", "Britt", "Helga", "Tove", "Agnes", "Klara", "Elin", "Thea",
        },
        surnames = {
            "Hansen", "Johansson", "Andersson", "Nielsen", "Jensen", "Larsen", "Pedersen", "Olsen", "Karlsson", "Nilsson",
            "Eriksson", "Christensen", "Andersen", "Johansen", "Persson", "Svensson", "Gustafsson", "Pettersson", "Jonsson", "Rasmussen",
            "Jørgensen", "Madsen", "Kristiansen", "Berg", "Haugen", "Hagen", "Lund", "Bakken", "Lindberg", "Lindqvist",
            "Lindström", "Bergström", "Sandberg", "Holm", "Dahl", "Strand", "Nyberg", "Engström", "Sørensen", "Thomsen",
            "Poulsen", "Mortensen", "Bakke", "Solberg", "Moen", "Halvorsen", "Eklund", "Sjöberg", "Wallin", "Lundgren",
            "Axelsson", "Magnusson", "Olofsson", "Ström",
        },
    },

    spanish = {
        male = {
            "José", "Antonio", "Manuel", "Francisco", "Juan", "David", "Javier", "Daniel", "Carlos", "Jesús",
            "Alejandro", "Miguel", "Rafael", "Pablo", "Sergio", "Fernando", "Jorge", "Luis", "Alberto", "Álvaro",
            "Diego", "Adrián", "Raúl", "Rubén", "Iván", "Óscar", "Andrés", "Ramón", "Enrique", "Vicente",
            "Joaquín", "Santiago", "Hugo", "Mateo", "Martín", "Lucas", "Marcos", "Gonzalo", "Ignacio", "Íñigo",
        },
        female = {
            "María", "Carmen", "Ana", "Isabel", "Laura", "Cristina", "Marta", "Lucía", "Elena", "Pilar",
            "Rosa", "Sara", "Paula", "Raquel", "Silvia", "Beatriz", "Patricia", "Rocío", "Alba", "Nuria",
            "Irene", "Andrea", "Claudia", "Sofía", "Martina", "Valeria", "Carla", "Inés", "Julia", "Teresa",
            "Mercedes", "Dolores", "Montserrat", "Lorena", "Noelia", "Natalia", "Esther", "Eva", "Ainhoa", "Marisol",
        },
        surnames = {
            "García", "Rodríguez", "González", "Fernández", "López", "Martínez", "Sánchez", "Pérez", "Gómez", "Martín",
            "Jiménez", "Ruiz", "Hernández", "Díaz", "Moreno", "Muñoz", "Álvarez", "Romero", "Alonso", "Gutiérrez",
            "Navarro", "Torres", "Domínguez", "Vázquez", "Ramos", "Gil", "Ramírez", "Serrano", "Blanco", "Molina",
            "Morales", "Suárez", "Ortega", "Delgado", "Castro", "Ortiz", "Rubio", "Marín", "Sanz", "Núñez",
            "Iglesias", "Medina", "Garrido", "Cortés", "Castillo", "Santos", "Lozano", "Guerrero", "Cano", "Prieto",
            "Méndez", "Cruz", "Calvo", "Gallego", "Vidal", "León", "Herrera", "Márquez", "Peña", "Flores",
        },
    },

    italian = {
        male = {
            "Giuseppe", "Giovanni", "Antonio", "Mario", "Luigi", "Francesco", "Angelo", "Vincenzo", "Pietro", "Salvatore",
            "Carlo", "Franco", "Domenico", "Bruno", "Paolo", "Michele", "Giorgio", "Aldo", "Sergio", "Luciano",
            "Marco", "Andrea", "Alessandro", "Matteo", "Lorenzo", "Leonardo", "Riccardo", "Davide", "Simone", "Federico",
            "Gabriele", "Tommaso", "Stefano", "Massimo", "Roberto", "Fabio", "Claudio", "Enrico", "Emanuele", "Nicola",
        },
        female = {
            "Maria", "Anna", "Giuseppina", "Rosa", "Angela", "Giovanna", "Teresa", "Lucia", "Carmela", "Francesca",
            "Giulia", "Sofia", "Aurora", "Alice", "Ginevra", "Emma", "Giorgia", "Martina", "Chiara", "Sara",
            "Alessandra", "Valentina", "Federica", "Elisa", "Silvia", "Laura", "Paola", "Elena", "Roberta", "Antonella",
            "Patrizia", "Daniela", "Simona", "Cristina", "Beatrice", "Bianca", "Camilla", "Ilaria", "Serena", "Noemi",
        },
        surnames = {
            "Rossi", "Russo", "Ferrari", "Esposito", "Bianchi", "Romano", "Colombo", "Ricci", "Marino", "Greco",
            "Bruno", "Gallo", "Conti", "De Luca", "Mancini", "Costa", "Giordano", "Rizzo", "Lombardi", "Moretti",
            "Barbieri", "Fontana", "Santoro", "Mariani", "Rinaldi", "Caruso", "Ferrara", "Galli", "Martini", "Leone",
            "Longo", "Gentile", "Martinelli", "Vitale", "Lombardo", "Serra", "Coppola", "De Santis", "D'Angelo", "Marchetti",
            "Parisi", "Villa", "Conte", "Ferraro", "Ferri", "Fabbri", "Bianco", "Marini", "Grasso", "Valentini",
            "Messina", "Sala", "De Angelis", "Gatti", "Pellegrini", "Palumbo", "Sanna", "Farina", "Rizzi", "Monti",
        },
    },

    polish = {
        male = {
            "Jan", "Piotr", "Krzysztof", "Andrzej", "Tomasz", "Paweł", "Michał", "Marcin", "Marek", "Grzegorz",
            "Józef", "Łukasz", "Adam", "Zbigniew", "Jerzy", "Tadeusz", "Mateusz", "Dariusz", "Mariusz", "Wojciech",
            "Ryszard", "Jakub", "Kazimierz", "Robert", "Rafał", "Jacek", "Janusz", "Mirosław", "Maciej", "Sławomir",
            "Jarosław", "Kamil", "Wiesław", "Roman", "Władysław", "Dawid", "Szymon", "Kacper", "Bartosz", "Filip",
        },
        female = {
            "Anna", "Maria", "Katarzyna", "Małgorzata", "Agnieszka", "Barbara", "Ewa", "Krystyna", "Elżbieta", "Magdalena",
            "Joanna", "Zofia", "Monika", "Teresa", "Danuta", "Natalia", "Karolina", "Marta", "Beata", "Dorota",
            "Halina", "Jadwiga", "Aleksandra", "Janina", "Grażyna", "Iwona", "Paulina", "Justyna", "Bożena", "Urszula",
            "Renata", "Agata", "Hanna", "Julia", "Zuzanna", "Maja", "Lena", "Wiktoria", "Oliwia", "Alicja",
        },
        surnames = {
            "Nowak", "Wójcik", "Kowalczyk", "Woźniak", "Mazur", "Krawczyk", "Kaczmarek", "Zając", "Król", "Wieczorek",
            "Wróbel", "Stępień", "Dudek", "Adamczyk", "Pawlak", "Sikora", "Baran", "Michalak", "Szewczyk", "Pietrzak",
            "Marciniak", "Duda", "Walczak", "Bąk", "Kubiak", "Wilk", "Lis", "Mazurek", "Sobczak", "Kołodziej",
            { male = "Kowalski", female = "Kowalska" },
            { male = "Wiśniewski", female = "Wiśniewska" },
            { male = "Lewandowski", female = "Lewandowska" },
            { male = "Kamiński", female = "Kamińska" },
            { male = "Zieliński", female = "Zielińska" },
            { male = "Szymański", female = "Szymańska" },
            { male = "Dąbrowski", female = "Dąbrowska" },
            { male = "Kozłowski", female = "Kozłowska" },
            { male = "Jankowski", female = "Jankowska" },
            { male = "Wojciechowski", female = "Wojciechowska" },
            { male = "Kwiatkowski", female = "Kwiatkowska" },
            { male = "Grabowski", female = "Grabowska" },
            { male = "Nowakowski", female = "Nowakowska" },
            { male = "Pawłowski", female = "Pawłowska" },
            { male = "Michalski", female = "Michalska" },
            { male = "Nowicki", female = "Nowicka" },
            { male = "Adamski", female = "Adamska" },
            { male = "Zawadzki", female = "Zawadzka" },
            { male = "Sadowski", female = "Sadowska" },
            { male = "Jasiński", female = "Jasińska" },
            { male = "Czarnecki", female = "Czarnecka" },
            { male = "Wysocki", female = "Wysocka" },
            { male = "Majewski", female = "Majewska" },
            { male = "Olszewski", female = "Olszewska" },
            { male = "Ostrowski", female = "Ostrowska" },
        },
    },
}

-- Settings that draw each name from a random style in a list. "all" is
-- every style.
TCNames.MIXES = {
    european = { "british", "irish", "french", "german", "dutch", "scandinavian", "spanish", "italian", "polish" },
}

-- The order styles are checked in when guessing a gender from a name.
-- British first: the only names before 041 were British.
TCNames.STYLE_ORDER = {
    "british", "irish", "american", "french", "german", "dutch", "scandinavian", "spanish", "italian", "polish",
}

TCNames.DEFAULT_STYLE = "british"

-- The style a single name is drawn from under a setting: the style itself,
-- or one picked from a mix.
function TCNames.pickStyle(styleKey)
    if styleKey == "all" then
        return TCNames.STYLE_ORDER[math.random(#TCNames.STYLE_ORDER)]
    end
    local mix = TCNames.MIXES[styleKey]
    if mix ~= nil then
        return mix[math.random(#mix)]
    end
    if TCNames.STYLES[styleKey] ~= nil then
        return styleKey
    end
    return TCNames.DEFAULT_STYLE
end

function TCNames.getSurname(entry, gender)
    if type(entry) == "table" then
        return entry[gender] or entry.male
    end
    return entry
end

-- "First Last" for a gender ("male"/"female") in a style or mix key.
function TCNames.generate(gender, styleKey)
    local style = TCNames.STYLES[TCNames.pickStyle(styleKey)]
    local firstNames = style[gender] or style.male
    local firstName = firstNames[math.random(#firstNames)]
    local surname = TCNames.getSurname(style.surnames[math.random(#style.surnames)], gender)
    -- Some first names are surnames too (Michel Michel, Bruno Bruno): one reroll.
    if surname == firstName then
        surname = TCNames.getSurname(style.surnames[math.random(#style.surnames)], gender)
    end
    return firstName .. " " .. surname
end

-- The gender of a first name in any style, or nil if it's in none. Where
-- styles disagree (Andrea), the first in STYLE_ORDER wins.
function TCNames.findGender(firstName)
    for _, styleKey in ipairs(TCNames.STYLE_ORDER) do
        local style = TCNames.STYLES[styleKey]
        for _, gender in ipairs({ "male", "female" }) do
            for _, candidate in ipairs(style[gender]) do
                if candidate == firstName then
                    return gender
                end
            end
        end
    end
    return nil
end
