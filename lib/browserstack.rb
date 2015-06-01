require 'selenium-webdriver'

class Browserstack
  def initialize(user, key)
    @user = user
    @key = key
  end
  
  def get_url
    "http://#{BROWSERSTACK_USER}:#{BROWSERSTACK_KEY}@hub.browserstack.com/wd/hub"
  end
  
  def snapshot(url)
    driver = Selenium::WebDriver.for(:remote,
      :url => get_url,
      :desired_capabilities => {
          browser: "Firefox",
          project: "snap-it-up"
        })
    driver.navigate.to url
    image = driver.screenshot_as(:png)
    driver.quit
    image
  end
end
